// cache_and_ram.v
module cache_and_ram #(
    parameter ADDR_WIDTH  = 12,       // 参与 cache 的地址位宽
    parameter INDEX_WIDTH = 6,        // 组号位宽 -> 组数 = 2^INDEX_WIDTH
    parameter DATA_WIDTH  = 32
)(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   mode,        // 1 = write, 0 = read
    input  wire [31:0]            address,     // CPU 视角地址（只用低 ADDR_WIDTH 位）
    input  wire [DATA_WIDTH-1:0]  data_in,     // CPU 写数据

    output reg  [DATA_WIDTH-1:0]  out,         // CPU 读数据
    output reg                    out_valid    // 读数据是否有效
);

    // ------------------------------
    // 地址拆分：低 INDEX_WIDTH 位做 index，高 TAG_WIDTH 位做 tag
    // ------------------------------
    localparam TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH;
    localparam LINE_NUM  = 1 << INDEX_WIDTH;

    wire [ADDR_WIDTH-1:0]  addr_in   = address[ADDR_WIDTH-1:0];
    wire [INDEX_WIDTH-1:0] index     = addr_in[INDEX_WIDTH-1:0];
    wire [TAG_WIDTH-1:0]   tag       = addr_in[ADDR_WIDTH-1:INDEX_WIDTH];

    // 用于 RAM 读（取新块）
    wire [ADDR_WIDTH-1:0]  ram_raddr = addr_in;

    // ------------------------------
    // 替换策略：每组一个 bit，0 表示选 way0，1 表示选 way1
    // 简单轮转，相当于每组的 random / round-robin
    // ------------------------------
    reg repl_bit [0:LINE_NUM-1];

    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < LINE_NUM; k = k + 1)
                repl_bit[k] <= 1'b0;
        end else begin
            // 在 miss 时才翻转 repl_bit[index]，下面逻辑里实现
        end
    end

    // 组合出当前组的替换候选 way
    wire [0:0] evict_way = repl_bit[index];

    // ------------------------------
    // Cache 2-way 实例
    // ------------------------------
    wire        cache_hit;
    wire [0:0]  cache_hit_way;
    wire [DATA_WIDTH-1:0] cache_dout;

    reg         cache_we;
    reg  [0:0]  cache_way_sel;
    reg  [DATA_WIDTH-1:0] cache_din;
    reg         cache_valid_in;
    reg         cache_dirty_in;

    wire        sel_valid;
    wire        sel_dirty;
    wire [TAG_WIDTH-1:0]   sel_tag;
    wire [DATA_WIDTH-1:0]  sel_data;

    cache_2way #(
        .INDEX_WIDTH(INDEX_WIDTH),
        .TAG_WIDTH  (TAG_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .WAYS       (2)
    ) u_cache (
        .clk       (clk),
        .rst       (rst),
        .index     (index),
        .tag_in    (tag),
        .we        (cache_we),
        .way_sel   (cache_way_sel),
        .din       (cache_din),
        .valid_in  (cache_valid_in),
        .dirty_in  (cache_dirty_in),
        .hit       (cache_hit),
        .hit_way   (cache_hit_way),
        .dout      (cache_dout),
        .sel_valid (sel_valid),
        .sel_dirty (sel_dirty),
        .sel_tag   (sel_tag),
        .sel_data  (sel_data)
    );

    // ------------------------------
    // RAM 实例：一写一读
    // 写端口用于 write-back，读端口用于 miss refill
    // ------------------------------
    reg                  ram_we;
    reg  [ADDR_WIDTH-1:0] ram_waddr;
    reg  [DATA_WIDTH-1:0] ram_din;
    wire [DATA_WIDTH-1:0] ram_dout;

    ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_ram (
        .clk   (clk),
        .we    (ram_we),
        .waddr (ram_waddr),
        .din   (ram_din),
        .raddr (ram_raddr),
        .dout  (ram_dout)
    );

    // ------------------------------
    // 主控制逻辑
    // 写策略：写回 + 写分配
    // 替换策略：每组轮换 evict_way
    // ------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out       <= {DATA_WIDTH{1'b0}};
            out_valid <= 1'b0;

            cache_we       <= 1'b0;
            cache_way_sel  <= 1'b0;
            cache_din      <= {DATA_WIDTH{1'b0}};
            cache_valid_in <= 1'b0;
            cache_dirty_in <= 1'b0;

            ram_we    <= 1'b0;
            ram_waddr <= {ADDR_WIDTH{1'b0}};
            ram_din   <= {DATA_WIDTH{1'b0}};
        end else begin
            // 默认不写 cache / ram
            cache_we       <= 1'b0;
            cache_valid_in <= 1'b0;
            cache_dirty_in <= 1'b0;
            ram_we         <= 1'b0;
            out_valid      <= 1'b0;

            // 选哪个 way：写命中时选择 hit_way，否则选择 evict_way
            cache_way_sel <= (cache_hit && mode) ? cache_hit_way : evict_way;

            if (mode) begin
                //--------------------------------------
                // 写操作：write-back + write-allocate
                //--------------------------------------
                if (cache_hit) begin
                    // 写命中：只写 cache，对应行 dirty=1，不立即写 RAM
                    cache_we       <= 1'b1;
                    cache_din      <= data_in;
                    cache_valid_in <= 1'b1;
                    cache_dirty_in <= 1'b1;    // 写回策略：标记为 dirty

                    // 不写 RAM（写回）
                    ram_we         <= 1'b0;
                end else begin
                    // 写 miss：写分配（write-allocate）
                    // 1) 若替换行是 valid 且 dirty，需要写回
                    if (sel_valid && sel_dirty) begin
                        ram_we    <= 1'b1;
                        ram_waddr <= {sel_tag, index};  // 用被替换行的 tag + index 还原地址
                        ram_din   <= sel_data;          // 写回旧数据
                    end

                    // 2) 在 cache 中分配新行，直接写入 data_in，并标记 dirty
                    cache_we       <= 1'b1;
                    cache_din      <= data_in;
                    cache_valid_in <= 1'b1;
                    cache_dirty_in <= 1'b1;  // 写后标记 dirty

                    // 3) 更新替换位：本组轮换下次替换的 way
                    repl_bit[index] <= ~repl_bit[index];

                    // 写操作一般不向 CPU 返回数据
                    out_valid <= 1'b0;
                end

            end else begin
                //--------------------------------------
                // 读操作
                //--------------------------------------
                if (cache_hit) begin
                    // 读命中：直接从 cache 取数据
                    out       <= cache_dout;
                    out_valid <= 1'b1;

                    // 不需要写 RAM / cache
                end else begin
                    // 读 miss：需要从 RAM 取数据，并可能写回被替换 dirty 行

                    // 1) 如果被替换行 dirty，则写回
                    if (sel_valid && sel_dirty) begin
                        ram_we    <= 1'b1;
                        ram_waddr <= {sel_tag, index};
                        ram_din   <= sel_data;
                    end

                    // 2) 从 RAM 读新数据（ram_dout 已经是 raddr 对应的值）
                    //    写入 cache，valid=1, dirty=0（因为是从内存刚读来的干净数据）
                    cache_we       <= 1'b1;
                    cache_din      <= ram_dout;
                    cache_valid_in <= 1'b1;
                    cache_dirty_in <= 1'b0;  // fresh from memory

                    // 3) 返回给 CPU
                    out       <= ram_dout;
                    out_valid <= 1'b1;

                    // 4) 更新该组的替换信息
                    repl_bit[index] <= ~repl_bit[index];
                end
            end
        end
    end

endmodule
