// cache_2way.v
module cache_2way #(
    parameter INDEX_WIDTH = 6,      // 组数 = 2^INDEX_WIDTH
    parameter TAG_WIDTH   = 6,      // tag 位宽
    parameter DATA_WIDTH  = 32,
    parameter WAYS        = 2       // 固定为 2-way
)(
    input  wire                    clk,
    input  wire                    rst,

    // 访问地址拆出来的部分
    input  wire [INDEX_WIDTH-1:0]  index,
    input  wire [TAG_WIDTH-1:0]    tag_in,

    // 写入数据（refill 或 write-hit 更新）
    input  wire                    we,        // 写使能
    input  wire [0:0]              way_sel,   // 要写 / 要探测的 way (0 或 1)
    input  wire [DATA_WIDTH-1:0]   din,
    input  wire                    valid_in,
    input  wire                    dirty_in,

    // 命中信息
    output wire                    hit,
    output wire [0:0]              hit_way,   // 哪个 way 命中
    output wire [DATA_WIDTH-1:0]   dout,      // 命中数据

    // 当前选中 way_sel 的行信息（用来做替换 & 写回）
    output wire                    sel_valid,
    output wire                    sel_dirty,
    output wire [TAG_WIDTH-1:0]    sel_tag,
    output wire [DATA_WIDTH-1:0]   sel_data
);

    localparam LINE_NUM = 1 << INDEX_WIDTH;

    // [way][index]
    reg                  valid_array [0:WAYS-1][0:LINE_NUM-1];
    reg                  dirty_array [0:WAYS-1][0:LINE_NUM-1];
    reg [TAG_WIDTH-1:0]  tag_array   [0:WAYS-1][0:LINE_NUM-1];
    reg [DATA_WIDTH-1:0] data_array  [0:WAYS-1][0:LINE_NUM-1];

    integer i, j;

    // 复位：清空 valid / dirty
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < WAYS; i = i + 1) begin
                for (j = 0; j < LINE_NUM; j = j + 1) begin
                    valid_array[i][j] <= 1'b0;
                    dirty_array[i][j] <= 1'b0;
                    tag_array[i][j]   <= {TAG_WIDTH{1'b0}};
                    data_array[i][j]  <= {DATA_WIDTH{1'b0}};
                end
            end
        end else begin
            // 写入选中的 way
            if (we) begin
                case (way_sel)
                    1'b0: begin
                        data_array [0][index] <= din;
                        tag_array  [0][index] <= tag_in;
                        valid_array[0][index] <= valid_in;
                        dirty_array[0][index] <= dirty_in;
                    end
                    1'b1: begin
                        data_array [1][index] <= din;
                        tag_array  [1][index] <= tag_in;
                        valid_array[1][index] <= valid_in;
                        dirty_array[1][index] <= dirty_in;
                    end
                endcase
            end
        end
    end

    // 命中判断（并行比较两个 way 的 tag）
    wire hit0 = valid_array[0][index] && (tag_array[0][index] == tag_in);
    wire hit1 = valid_array[1][index] && (tag_array[1][index] == tag_in);

    assign hit = hit0 | hit1;

    assign hit_way =
        hit1 ? 1'b1 : 1'b0;  // 若 hit1=1，则选 1，否则默认 0（假设不会双命中）

    assign dout =
        hit0 ? data_array[0][index] :
        hit1 ? data_array[1][index] :
        {DATA_WIDTH{1'b0}};

    // 选中 way_sel 的那一行（用来查看是否 valid / dirty，以及 tag/data）
    assign sel_valid =
        (way_sel == 1'b0) ? valid_array[0][index] : valid_array[1][index];

    assign sel_dirty =
        (way_sel == 1'b0) ? dirty_array[0][index] : dirty_array[1][index];

    assign sel_tag =
        (way_sel == 1'b0) ? tag_array[0][index] : tag_array[1][index];

    assign sel_data =
        (way_sel == 1'b0) ? data_array[0][index] : data_array[1][index];

endmodule
