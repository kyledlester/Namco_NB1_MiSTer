// Namco NB-1 MiSTer core -- true dual-port byte-enabled RAM (M8).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Two independent 16-bit ports on one array, each with byte enables and one
// clk_sys of read latency, both in clk_sys. Used for the NB-1 shared RAM:
// port A = 68EC020 (nb1_main_bus), port B = C75 (nb1_c75).
// Simultaneous writes to the same word from both ports in the same cycle
// are undefined (M10K); the two CPUs never do that in the same clk_sys in
// practice, and the physical dual-port RAM arbitrates it [UNKNOWN].
// Read-during-write on the same port returns old data (no_rw_check: no
// client uses it).
module nb1_dp_ram #(parameter int WORDS = 16384, parameter int AW = 14) (
    input  wire          clk_sys,
    input  wire          en_a,
    input  wire          we_a,
    input  wire [AW-1:0] addr_a,
    input  wire [15:0]   wdata_a,
    input  wire [1:0]    be_a,
    output reg  [15:0]   rdata_a = '0,
    input  wire          en_b,
    input  wire          we_b,
    input  wire [AW-1:0] addr_b,
    input  wire [15:0]   wdata_b,
    input  wire [1:0]    be_b,
    output reg  [15:0]   rdata_b = '0
);
    // One 8-bit true-dual-port array per byte lane: Quartus 17.0 Standard does
    // not infer a byte-enabled true-dual-port RAM (Error 276003 with the
    // packed-lane coding), but infers two plain TDP arrays; the lane's write
    // enable is we & be. hi = D15:8 (68020 even byte), lo = D7:0.
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] hi[0:WORDS-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] lo[0:WORDS-1];
// synthesis translate_off
`ifndef SYNTHESIS
    initial for (int i = 0; i < WORDS; i++) begin hi[i] = '0; lo[i] = '0; end
`endif
// synthesis translate_on
    always @(posedge clk_sys) if (en_a) begin
        if (we_a && be_a[1]) hi[addr_a] <= wdata_a[15:8];
        rdata_a[15:8] <= hi[addr_a];
    end
    always @(posedge clk_sys) if (en_a) begin
        if (we_a && be_a[0]) lo[addr_a] <= wdata_a[7:0];
        rdata_a[7:0] <= lo[addr_a];
    end
    always @(posedge clk_sys) if (en_b) begin
        if (we_b && be_b[1]) hi[addr_b] <= wdata_b[15:8];
        rdata_b[15:8] <= hi[addr_b];
    end
    always @(posedge clk_sys) if (en_b) begin
        if (we_b && be_b[0]) lo[addr_b] <= wdata_b[7:0];
        rdata_b[7:0] <= lo[addr_b];
    end
endmodule
