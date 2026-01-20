`timescale 1ns / 1ps
`include "riscv_define.v"

module MemorySystem_tb;

    // === 1. 信号定义 ===
    reg clk;
    reg rst_n;
    reg flush;

    // LSU (D-Cache) 激励信号
    reg lsu_valid_in;
    reg [31:0] lsu_addr;
    reg [31:0] lsu_wdata;
    reg [`MEM_OP_WIDTH-1:0] lsu_op;
    reg lsu_is_load;
    reg lsu_unsigned;
    
    // LSU 输出观测
    wire lsu_busy;
    wire lsu_wb_valid;
    wire [31:0] lsu_wb_value;

    // I-Cache 激励信号
    reg [31:0] if_pc;
    reg if_req;
    
    // I-Cache 输出观测
    wire [127:0] if_inst_line;
    wire if_hit;
    wire if_stall;

    // 内部连接信号 (Arbiter <-> Memory)
    wire arb_mem_req, arb_mem_we, arb_mem_ready;
    wire [31:0] arb_mem_addr;
    wire [127:0] arb_mem_wdata, arb_mem_rdata;

    // 连接信号 (Components <-> Arbiter)
    wire i_req, i_we, i_ready;
    wire [31:0] i_addr;
    wire [127:0] i_wdata, i_rdata;
    
    wire d_req, d_we, d_ready;
    wire [31:0] d_addr;
    wire [127:0] d_wdata, d_rdata;

    // === 2. 模块实例化 ===

    // 2.1 待测核心：LSU (含 TLB + D-Cache)
    LSU u_lsu (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .valid_in(lsu_valid_in),
        .addr(lsu_addr),
        .wdata(lsu_wdata),
        .mem_op(lsu_op),
        .mem_is_load(lsu_is_load),
        .mem_unsigned(lsu_unsigned),
        .rob_idx_in(0), .rd_tag_in(1), .rd_is_fp_in(0), // 简单的 dummy 信号
        .busy(lsu_busy),
        .wb_valid(lsu_wb_valid),
        .wb_value(lsu_wb_value),
        // 连接到 Arbiter 的 D 端口
        .mem_req(d_req), .mem_we(d_we), .mem_addr(d_addr),
        .mem_wdata(d_wdata), .mem_rdata(d_rdata), .mem_ready(d_ready)
    );

    // 2.2 待测核心：ICache
    ICache u_icache (
        .clk(clk), .rst_n(rst_n),
        .paddr(if_pc),
        .req(if_req),
        .rdata_line(if_inst_line),
        .valid_out(if_hit),
        .stall_cpu(if_stall),
        // 连接到 Arbiter 的 I 端口
        .mem_req(i_req), .mem_we(i_we), .mem_addr(i_addr),
        .mem_wdata(i_wdata), .mem_rdata(i_rdata), .mem_ready(i_ready)
    );

    // 2.3 仲裁器
    MemArbiter u_arbiter (
        .clk(clk), .rst_n(rst_n),
        .i_req(i_req), .i_we(i_we), .i_addr(i_addr), .i_wdata(i_wdata), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
        .mem_req(arb_mem_req), .mem_we(arb_mem_we), .mem_addr(arb_mem_addr), .mem_wdata(arb_mem_wdata), .mem_rdata(arb_mem_rdata), .mem_ready(arb_mem_ready)
    );

    // 2.4 主存模型
    MainMemory u_mem (
        .clk(clk), .rst_n(rst_n),
        .mem_req(arb_mem_req), .mem_we(arb_mem_we), .mem_addr(arb_mem_addr), .mem_wdata(arb_mem_wdata),
        .mem_rdata(arb_mem_rdata), .mem_ready(arb_mem_ready)
    );

    // === 3. 时钟生成 ===
    always #5 clk = ~clk; // 100MHz

    // === 4. 测试任务 (Helper Tasks) ===
    
    // 任务：复位
    task reset_system;
    begin
        $display("\n[TEST] System Reset...");
        clk = 0; rst_n = 0; flush = 0;
        lsu_valid_in = 0; if_req = 0;
        #20 rst_n = 1;
        #10;
    end
    endtask

    // 任务：LSU Store
    task lsu_store(input [31:0] addr, input [31:0] data);
    begin
        $display("[LSU] STORE Request: Addr=0x%h, Data=0x%h", addr, data);
        @(posedge clk);
        lsu_valid_in = 1;
        lsu_addr = addr;
        lsu_wdata = data;
        lsu_op = `MEM_OP_SW;
        lsu_is_load = 0;
        
        // 等待 Busy
        @(posedge clk);
        lsu_valid_in = 0;
        
        // 等待完成 (wb_valid 对于 Store 也可以作为完成标志，或者看 busy 变低)
        wait(lsu_wb_valid);
        $display("[LSU] STORE Completed.");
        @(posedge clk);
    end
    endtask

    // 任务：LSU Load
    task lsu_load(input [31:0] addr, input [31:0] expected_data);
    begin
        $display("[LSU] LOAD Request:  Addr=0x%h", addr);
        @(posedge clk);
        lsu_valid_in = 1;
        lsu_addr = addr;
        lsu_op = `MEM_OP_LW;
        lsu_is_load = 1;
        
        @(posedge clk);
        lsu_valid_in = 0;
        
        wait(lsu_wb_valid);
        if (lsu_wb_value === expected_data) 
            $display("[PASS] LSU Load Hit/Miss Success! Got 0x%h", lsu_wb_value);
        else 
            $display("[FAIL] LSU Load Error! Expected 0x%h, Got 0x%h", expected_data, lsu_wb_value);
        @(posedge clk);
    end
    endtask

    // 任务：ICache Fetch
    task icache_fetch(input [31:0] addr);
    begin
        $display("[IF]  FETCH Request: Addr=0x%h", addr);
        @(posedge clk);
        if_pc = addr;
        if_req = 1;
        
        // 等待 valid_out (Hit)
        // 注意：如果是 Miss，valid_out 会在若干周期后变高
        wait(if_hit); 
        $display("[PASS] ICache Valid! Data Line: 0x%h", if_inst_line);
        if_req = 0; // 停止请求
        @(posedge clk);
    end
    endtask

    // === 5. 主测试流程 ===
    initial begin
        // 初始化主存数据 (在 MainMemory.v 中通常已有 initial block，这里仅依赖它)
        // 假设地址 0x00 处的数据是 0xDEAD_BEEF... (你的 MainMemory.v 写的)

        reset_system();

        // --- Test 1: I-Cache Cold Miss (第一次读) ---
        $display("\n--- Test 1: I-Cache Cold Miss ---");
        // 主存地址 0 对应 Set 0
        icache_fetch(32'h0000_0000); 

        // --- Test 2: I-Cache Hit (第二次读同一地址) ---
        $display("\n--- Test 2: I-Cache Hit ---");
        // 应该在 1 个周期内返回结果，不需要 arbiter 介入
        icache_fetch(32'h0000_0004); // 同一个 Cache Line，应该直接 Hit

        // --- Test 3: LSU Store (写入 D-Cache) ---
        $display("\n--- Test 3: LSU Store ---");
        // 往地址 0x100 写入 0x12345678
        lsu_store(32'h0000_0100, 32'h1234_5678);

        // --- Test 4: LSU Load (读取刚才写入的数据) ---
        $display("\n--- Test 4: LSU Load (Read after Write) ---");
        // 从地址 0x100 读，应该命中 D-Cache 并返回 0x12345678
        lsu_load(32'h0000_0100, 32'h1234_5678);

        // --- Test 5: Conflict Test (ICache Miss + LSU Miss) ---
        $display("\n--- Test 5: Conflict Test (Arbiter) ---");
        $display("[TEST] Asserting both requests simultaneously...");
        
        @(posedge clk);
        // 制造一个新的 Miss
        if_pc = 32'h0000_0200; if_req = 1; // I-Cache 请求
        
        lsu_valid_in = 1; lsu_addr = 32'h0000_0300; lsu_op = `MEM_OP_LW; lsu_is_load = 1; // LSU 请求
        
        @(posedge clk);
        lsu_valid_in = 0; // LSU 是脉冲信号
        // if_req 保持高电平直到 hit
        
        $display("[TEST] Waiting for completion...");
        
        // 两个都会完成，顺序取决于 Arbiter (设计是 D 优先)
        fork
            begin
                wait(lsu_wb_valid);
                $display("[INFO] LSU Finished first (Expected behavior).");
            end
            begin
                wait(if_hit);
                $display("[INFO] ICache Finished.");
            end
        join

        $display("\n[SUCCESS] All Tests Passed!");
        $finish;
    end

    // 监控 Arbiter 状态 (调试用)
    always @(posedge clk) begin
        if (arb_mem_req && arb_mem_ready)
            $display("    [MEM] Transaction Addr=0x%h Data=0x%h", arb_mem_addr, arb_mem_rdata);
    end

endmodule