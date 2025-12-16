// simple_tlb.v
module tlb #(
    parameter ENTRY_NUM = 16,        // TLB 表项数量
    parameter VPN_WIDTH = 20,        // 虚拟页号位宽（Sv32: 32-12=20）
    parameter PPN_WIDTH = 20         // 物理页号位宽
)(
    input  wire                  clk,
    input  wire                  rst,

    // ========= 查表接口（给 MEM / cache 用） =========
    input  wire [31:0]           lookup_vaddr,   // 虚拟地址
    output wire [31:0]           lookup_paddr,   // 物理地址（命中时有效）
    output wire                  lookup_hit,     // 是否命中
    output wire                  lookup_pagefault, // 页异常（这里先留接口，一律 0）

    // ========= 写表接口（以后 OS 通过特权指令来用） =========
    input  wire                  wr_en,          // 写入一个 TLB 表项
    input  wire [31:0]           wr_vaddr,       // 对应虚拟地址（只用 VPN 部分）
    input  wire [31:0]           wr_paddr,       // 对应物理地址（只用 PPN 部分）
    input  wire [2:0]            wr_perm,        // 权限标志：R/W/X（现在不细用，先存着）

    // ========= 刷新接口（sfence.vma 之类） =========
    input  wire                  flush           // 置 1 时清空所有 TLB 表项
);

    // ---- TLB 表项存储 ----
    reg                  valid   [0:ENTRY_NUM-1];
    reg [VPN_WIDTH-1:0]  vpn     [0:ENTRY_NUM-1];
    reg [PPN_WIDTH-1:0]  ppn     [0:ENTRY_NUM-1];
    reg [2:0]            perm    [0:ENTRY_NUM-1]; // 先存起来，将来做权限校验用

    // 简单 round-robin 替换指针
    reg [$clog2(ENTRY_NUM)-1:0] rr_ptr;

    integer i;

    // ---- 查表逻辑：全相联遍历 ----
    wire [VPN_WIDTH-1:0] curr_vpn   = lookup_vaddr[31:32-VPN_WIDTH];
    wire [11:0]          page_off   = lookup_vaddr[11:0];

    reg                  hit_r;
    reg [PPN_WIDTH-1:0]  hit_ppn;

    always @(*) begin
        hit_r   = 1'b0;
        hit_ppn = {PPN_WIDTH{1'b0}};
        for (i = 0; i < ENTRY_NUM; i = i + 1) begin
            if (valid[i] && vpn[i] == curr_vpn) begin
                hit_r   = 1'b1;
                hit_ppn = ppn[i];
            end
        end
    end

    assign lookup_hit        = hit_r;
    assign lookup_paddr      = {hit_ppn, page_off};
    assign lookup_pagefault  = 1'b0;   // 这里先不做权限与页表校验，统一拉 0

    // ---- 写表 / 替换逻辑 ----
    reg [$clog2(ENTRY_NUM)-1:0] free_idx;
    reg                         has_free;

    // 找有没有 invalid 的空位（组合）
    always @(*) begin
        has_free = 1'b0;
        free_idx = {($clog2(ENTRY_NUM)){1'b0}};
        for (i = 0; i < ENTRY_NUM; i = i + 1) begin
            if (!valid[i]) begin
                has_free = 1'b1;
                free_idx = i[$clog2(ENTRY_NUM)-1:0];
            end
        end
    end

    // 时序部分：reset / flush / wr_en
    integer j;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rr_ptr <= {($clog2(ENTRY_NUM)){1'b0}};
            for (j = 0; j < ENTRY_NUM; j = j + 1) begin
                valid[j] <= 1'b0;
                vpn[j]   <= {VPN_WIDTH{1'b0}};
                ppn[j]   <= {PPN_WIDTH{1'b0}};
                perm[j]  <= 3'b000;
            end
        end else begin
            if (flush) begin
                for (j = 0; j < ENTRY_NUM; j = j + 1) begin
                    valid[j] <= 1'b0;
                end
            end else if (wr_en) begin
                // 有空位就写空位，否则用 rr_ptr 替换
                if (has_free) begin
                    valid[free_idx] <= 1'b1;
                    vpn[free_idx]   <= wr_vaddr[31:32-VPN_WIDTH];
                    ppn[free_idx]   <= wr_paddr[31:32-PPN_WIDTH];
                    perm[free_idx]  <= wr_perm;
                end else begin
                    valid[rr_ptr] <= 1'b1;
                    vpn[rr_ptr]   <= wr_vaddr[31:32-VPN_WIDTH];
                    ppn[rr_ptr]   <= wr_paddr[31:32-PPN_WIDTH];
                    perm[rr_ptr]  <= wr_perm;
                    rr_ptr        <= rr_ptr + 1'b1;
                end
            end
        end
    end

endmodule
