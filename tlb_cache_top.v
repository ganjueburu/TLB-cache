// tlb_cache_top.v
module tlb_cache_top #(
    parameter ADDR_WIDTH  = 12,
    parameter INDEX_WIDTH = 6,
    parameter DATA_WIDTH  = 32,
    parameter TLB_ENTRIES = 16
)(
    input  wire                   clk,
    input  wire                   rst,

    // ========= CPU 侧接口（虚拟地址） =========
    input  wire                   mode,         // 1=write, 0=read
    input  wire [31:0]            vaddr,        // 虚拟地址
    input  wire [DATA_WIDTH-1:0]  data_in,

    output wire [DATA_WIDTH-1:0]  data_out,
    output wire                   data_out_valid,

    // ========= MMU / TLB 控制 =========
    input  wire                   mmu_en,       // 1: 开启地址翻译; 0: VA=PA 直通

    // TLB 写口
    input  wire                   tlb_wr_en,
    input  wire [31:0]            tlb_wr_vaddr,
    input  wire [31:0]            tlb_wr_paddr,
    input  wire [2:0]             tlb_wr_perm,
    input  wire                   tlb_flush,

    // 供上层观察/调试
    output wire                   tlb_hit,
    output wire                   tlb_miss
);

    // ========= TLB 实例 =========
    wire [31:0] tlb_paddr;
    wire        tlb_lookup_hit;
    wire        tlb_pagefault_unused;

    tlb #(
        .ENTRY_NUM (TLB_ENTRIES),
        .VPN_WIDTH (20),
        .PPN_WIDTH (20)
    ) u_tlb (
        .clk              (clk),
        .rst              (rst),

        .lookup_vaddr     (vaddr),
        .lookup_paddr     (tlb_paddr),
        .lookup_hit       (tlb_lookup_hit),
        .lookup_pagefault (tlb_pagefault_unused),

        .wr_en            (tlb_wr_en),
        .wr_vaddr         (tlb_wr_vaddr),
        .wr_paddr         (tlb_wr_paddr),
        .wr_perm          (tlb_wr_perm),

        .flush            (tlb_flush)
    );

    assign tlb_hit  = mmu_en ? tlb_lookup_hit : 1'b1;
    assign tlb_miss = mmu_en ? ~tlb_lookup_hit : 1'b0;

    // ======== 选择给 cache 的物理地址 ========
    // 在 MMU 打开时，如果 TLB miss，就直接 VA 当 PA 用；
    wire [31:0] paddr =
        (mmu_en && tlb_lookup_hit) ? tlb_paddr :
        /* mmu 关 或 miss */        vaddr;

    cache_and_ram #(
        .ADDR_WIDTH  (ADDR_WIDTH),
        .INDEX_WIDTH (INDEX_WIDTH),
        .DATA_WIDTH  (DATA_WIDTH)
    ) u_cache_and_ram (
        .clk      (clk),
        .rst      (rst),
        .mode     (mode),
        .address  (paddr),
        .data_in  (data_in),
        .out      (data_out),
        .out_valid(data_out_valid)
    );

endmodule
