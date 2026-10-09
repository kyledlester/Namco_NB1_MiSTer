// Namco NB-1 MiSTer core -- M26 bench: DDR3 fast ROM loading (nb1_ddr_load -> nb1_rom_loader).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// A hps_io-shaped driver performs, in order:
//   1. a DDR3 ("fast") download of index 0: FIO_FILE_TX with the length in ioctl_addr, no data words; the
//      image (byte k = f(k)) is already in a DDR3 model at word BASE (Main_MiSTer's shmem_put); then
//   2. a normal SPI download of index 0 (ioctl_addr from 0, one WIDE word per ioctl_wr, honouring ioctl_wait).
// The production muxing of NB1.sv is reproduced (st_* = replay while active, else hps_io). A memory responder
// (random latency) records every loader write. Checks: every byte of both streams reaches memory with
// MAME's byte order (big-endian storage, nb1_rom_loader), the loader's stream_bytes equals the length,
// rom_loaded is set, no loader error, the replay never drives the DDR3 port while the other masters are
// busy, and the replay is inactive during the normal download.
`timescale 1ns/1ps
module m26_ddr_load_tb;
    import nb1_mem_pkg::*;
    reg clk = 0;
    always #5 clk = ~clk;
    localparam int LEN1 = 'h3000;          // fast download length (bytes)
    localparam int LEN2 = 'h0800;          // normal download length
    localparam [28:0] BASE = 29'h0620_0000;
    function automatic [7:0] f1(input int k); f1 = 8'((k * 7) ^ (k >> 8) ^ 8'h5A); endfunction
    function automatic [7:0] f2(input int k); f2 = 8'((k * 13) + 8'h21); endfunction

    // hps_io side
    reg         dl = 0, wr = 0;
    reg  [15:0] idx = 0;
    reg  [26:0] addr = 0;
    reg  [15:0] dout = 0;
    // replay
    wire        dl_active, dl_busy, dl_download, dl_wr, dl_own;
    wire [26:0] dl_addr;
    wire [15:0] dl_dout;
    wire [7:0]  bc;
    wire [28:0] daddr;
    wire        drd;
    reg         ddr_busy = 0;
    reg  [63:0] ddr_dout = 0;
    reg         ddr_ready = 0;
    reg         others_busy = 0;
    // NB1.sv mux
    wire        st_download = dl_active ? dl_download : dl;
    wire [15:0] st_index    = dl_active ? 16'd0 : idx;
    wire        st_wr       = dl_active ? dl_wr : wr;
    wire [26:0] st_addr     = dl_active ? dl_addr : addr;
    wire [15:0] st_dout     = dl_active ? dl_dout : dout;
    wire        ld_wait;
    // loader + memory responder
    wire        rq_valid, rq_we, rsp_valid;
    wire [3:0]  rq_region, rq_be;
    wire [24:0] rq_offset;
    wire [31:0] rq_wdata;
    reg         rq_ready = 0, rsp = 0;
    wire        loading, loaded, e_ov, e_rg, e_wr;
    wire [26:0] sbytes;

    nb1_ddr_load #(.INDEX(16'd0), .BASE(BASE)) dut (
        .clk_sys(clk), .init(1'b0), .ioctl_download(dl), .ioctl_index(idx), .ioctl_addr(addr),
        .ld_download(dl_download), .ld_wr(dl_wr), .ld_addr(dl_addr), .ld_dout(dl_dout), .ld_wait(ld_wait),
        .active(dl_active), .busy(dl_busy), .loads(), .others_idle(!others_busy), .ddr_own(dl_own),
        .ddr_busy(ddr_busy || others_busy), .ddr_burstcnt(bc), .ddr_addr(daddr), .ddr_rd(drd),
        .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_ready));
    nb1_rom_loader #(.INDEX(16'd0)) ld (
        .clk_sys(clk), .init(1'b0), .ioctl_download(st_download), .ioctl_index(st_index), .ioctl_wr(st_wr),
        .ioctl_addr(st_addr), .ioctl_dout(st_dout), .ioctl_wait(ld_wait),
        .req_valid(rq_valid), .req_ready(rq_ready), .req_region(rq_region), .req_offset(rq_offset),
        .req_we(rq_we), .req_wdata(rq_wdata), .req_be(rq_be), .rsp_valid(rsp), .rsp_err(1'b0),
        .loading(loading), .rom_loaded(loaded), .stream_bytes(sbytes), .err_overrun(e_ov), .err_range(e_rg),
        .err_write(e_wr));

    // memory: byte image of region OBJ (stream 0x0000000.. maps to OBJ offset 0..)
    reg [7:0] mem [0:LEN1-1];
    int lat = 0;
    always @(posedge clk) begin
        rq_ready <= 0; rsp <= 0;
        if (rq_valid && !rq_ready && lat == 0) begin
            rq_ready <= 1; lat <= 2 + ($urandom % 12);
            for (int b = 0; b < 4; b++)
                if (rq_be[3 - b]) mem[{rq_offset[24:2], 2'b00} + b] <= rq_wdata[8 * (3 - b) +: 8];
        end
        if (lat > 0) begin lat <= lat - 1; if (lat == 1) rsp <= 1; end
    end

    // DDR3 model: burst reads of the fast image, random latency; flags the port being used while others are busy
    int errors = 0;
    always @(posedge clk) begin
        if ((drd) && others_busy) begin errors++; $display("ERROR replay read while others busy"); end
    end
    initial begin : ddr
        forever begin
            @(posedge clk);
            if (drd && !ddr_busy && !others_busy) begin
                automatic int w = int'(daddr - BASE);
                automatic int n = bc;
                repeat (3 + ($urandom % 20)) @(posedge clk);
                for (int i = 0; i < n; i++) begin
                    for (int b = 0; b < 8; b++) ddr_dout[8 * b +: 8] = f1(8 * (w + i) + b);
                    ddr_ready = 1; @(posedge clk); ddr_ready = 0;
                    if ($urandom % 3 == 0) @(posedge clk);
                end
            end
        end
    end
    // other DDR3 masters: busy now and then
    initial begin
        forever begin repeat (200 + $urandom % 300) @(posedge clk); others_busy = 1; repeat (50) @(posedge clk); others_busy = 0; end
    end

    initial begin
        // 1. fast download
        repeat (5) @(posedge clk);
        idx = 0; addr = LEN1; dl = 1;
        repeat (40) @(posedge clk);
        if (ld.loading) begin errors++; $display("ERROR loader saw the fast download itself"); end
        dl = 0; addr = LEN1 + 2;
        wait (dl_busy); wait (!dl_busy);
        repeat (20) @(posedge clk);
        for (int k = 0; k < LEN1; k++) if (mem[k] !== f1(k)) begin
            errors++; if (errors < 10) $display("ERROR fast byte %0x = %02x expected %02x", k, mem[k], f1(k));
        end
        if (!loaded || sbytes != LEN1 || e_ov || e_rg || e_wr) begin
            errors++; $display("ERROR fast: loaded %b bytes %0x err %b%b%b", loaded, sbytes, e_ov, e_rg, e_wr);
        end
        // 2. normal download
        idx = 0; addr = 0; dl = 1;
        @(posedge clk);
        for (int k = 0; k < LEN2; k += 2) begin
            addr = k; dout = {f2(k + 1), f2(k)}; wr = 1; @(posedge clk); wr = 0;
            @(posedge clk); while (ld_wait) @(posedge clk);
            if (dl_active) begin errors++; $display("ERROR replay active during a normal download"); end
        end
        dl = 0; addr = LEN2;
        repeat (40) @(posedge clk);
        for (int k = 0; k < LEN2; k++) if (mem[k] !== f2(k)) begin
            errors++; if (errors < 20) $display("ERROR normal byte %0x = %02x expected %02x", k, mem[k], f2(k));
        end
        if (!loaded || sbytes != LEN2) begin errors++; $display("ERROR normal: loaded %b bytes %0x", loaded, sbytes); end
        if (errors == 0) $display("PASS M26 DDR LOAD: %0d-byte DDR3 image replayed byte-exact, normal download unaffected", LEN1);
        else             $display("FAIL M26 DDR LOAD: %0d errors", errors);
        $finish;
    end
endmodule
