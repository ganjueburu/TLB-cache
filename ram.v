// ram.v
module ram #(
    parameter ADDR_WIDTH = 12,   // RAM 深度 = 2^ADDR_WIDTH
    parameter DATA_WIDTH = 32
)(
    input  wire                   clk,

    // 写端口（用于写回 dirty 行）
    input  wire                   we,
    input  wire [ADDR_WIDTH-1:0]  waddr,
    input  wire [DATA_WIDTH-1:0]  din,

    // 读端口（用于读 miss 时从内存取数据）
    input  wire [ADDR_WIDTH-1:0]  raddr,
    output wire [DATA_WIDTH-1:0]  dout
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // 写：同步
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= din;
    end

    // 读：组合（教学友好，零延迟）
    assign dout = mem[raddr];

endmodule
