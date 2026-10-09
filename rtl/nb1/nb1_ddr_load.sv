// Namco NB-1 MiSTer core -- fast ROM loading through DDR3 (M26).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// [MiSTer Main_MiSTer support/arcade/mra_loader.cpp rom_finish, user_io_set_download] When an MRA's
// <rom> carries address="0x...", Main_MiSTer assembles the whole ROM in HPS memory, starts the
// download with the stream LENGTH in place of a start address (hps_io: ioctl_addr = length,
// ioctl_download high, no FIO_FILE_TX_DAT words at all), copies the image into DDR3 at that
// address with one memcpy (shmem_put), and ends the download. Without the attribute (or with an
// older Main_MiSTer) the stream comes word by word over the SPI link as before -- much slower
// (the ~24 MB NB-1 stream took tens of seconds).
//
// [IMPLEMENTATION] This module turns the DDR3 image back into the same word stream, so nothing
// downstream changes (nb1_rom_loader, nb1_rom_check, the C75 internal-ROM write):
//   detect   a download of index INDEX whose ioctl_addr is non-zero in its first cycle is a DDR3
//            download (a normal one starts at address 0); the length is taken from ioctl_addr then.
//   mask     that download is hidden from the stream consumers (ld_download stays low).
//   replay   when it ends (the image is complete in DDR3), ld_download rises, the image is read in
//            16-beat bursts (16 x 8 bytes) and offered as WIDE=1 words -- ld_addr = 2k,
//            ld_dout = {byte 2k+1, byte 2k} (DDR3 is little-endian: 16-bit lane j of a beat is
//            bytes 2j, 2j+1, exactly hps_io's WIDE word) -- one ld_wr per word, only while the
//            consumer's ld_wait is low and never in two consecutive clocks (hps_io's pacing: the
//            loader raises its wait in the ld_wr clock). After the last word ld_download falls.
//   busy     high from the detection to the end of the replay (the core holds its devices in reset).
// DDR3 port: the replay owns it (ddr_own) only between other masters' transactions: it requests,
// waits for `others_idle` (no request asserted by the other masters, none of their reads still
// returning), then owns the port until its last burst has returned. While it owns the port, NB1.sv
// shows the other masters a busy port so they hold their requests.
module nb1_ddr_load #(
    parameter [15:0] INDEX = 16'd0,
    parameter [28:0] BASE  = 29'h0620_0000     // 64-bit word address of byte 0x31000000 (MRA address)
) (
    input  wire        clk_sys,
    input  wire        init,
    // hps_io
    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire [26:0] ioctl_addr,
    // replayed stream (WIDE=1 semantics) for the index-INDEX consumers
    output reg         ld_download = 1'b0,
    output reg         ld_wr = 1'b0,
    output reg  [26:0] ld_addr = '0,
    output reg  [15:0] ld_dout = '0,
    input  wire        ld_wait,
    output wire        active,            // detection .. end of replay: a DDR3 download is in progress
    output reg         busy = 1'b0,       // = active (registered), for the reset request
    output reg  [31:0] loads = '0,        // DDR3 downloads completed (diagnostic)
    // DDR3 master (DDRAM_CLK = clk_sys)
    input  wire        others_idle,
    output reg         ddr_own = 1'b0,
    input  wire        ddr_busy,
    output wire [7:0]  ddr_burstcnt,
    output reg  [28:0] ddr_addr = '0,
    output reg         ddr_rd = 1'b0,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready
);
    localparam int BURST = 16;
    assign ddr_burstcnt = 8'(BURST);

    wire sel = ioctl_download && (ioctl_index == INDEX);
    reg  sel_q = 1'b0;
    reg  fast = 1'b0;                  // the current/last index-INDEX download is a DDR3 one
    reg  [26:0] len = '0;              // stream bytes

    localparam [2:0] S_IDLE = 3'd0, S_WAITDL = 3'd1, S_REQ = 3'd2, S_RD = 3'd3, S_BEATS = 3'd4,
                     S_EMIT = 3'd5, S_DONE = 3'd6;
    reg  [2:0]  st = S_IDLE;
    reg  [63:0] buf_mem [0:BURST-1];
    reg  [3:0]  bw = '0;               // beat being written into buf_mem
    reg  [3:0]  br = '0;               // beat being emitted
    reg  [1:0]  lane = '0;             // 16-bit lane of that beat
    reg  [26:0] next_addr = '0;        // stream byte address of the next word to emit
    reg  [28:0] waddr = '0;            // DDR3 word address of the next burst
    reg         wr_q = 1'b0;
    wire [63:0] cur = buf_mem[br];

    assign active = (st != S_IDLE) || (sel && !sel_q && ioctl_addr != 27'd0);

    always @(posedge clk_sys) begin
        sel_q <= sel;
        ld_wr <= 1'b0;
        busy  <= active;
        if (init) begin
            st <= S_IDLE; fast <= 1'b0; ld_download <= 1'b0; ddr_own <= 1'b0; ddr_rd <= 1'b0;
        end else case (st)
            S_IDLE: if (sel && !sel_q) begin
                fast <= (ioctl_addr != 27'd0);
                len  <= ioctl_addr;
                if (ioctl_addr != 27'd0) st <= S_WAITDL;
            end
            S_WAITDL: if (!sel) begin         // Main_MiSTer finished copying the image
                ld_download <= 1'b1;
                next_addr   <= '0;
                waddr       <= BASE;
                st          <= S_REQ;
            end
            S_REQ: if (next_addr >= len) st <= S_DONE;
                   else if (ddr_own || others_idle) begin
                       ddr_own <= 1'b1;
                       ddr_rd  <= 1'b1;
                       ddr_addr <= waddr;
                       st      <= S_RD;
                   end
            S_RD: if (!ddr_busy) begin ddr_rd <= 1'b0; bw <= '0; st <= S_BEATS; end
            S_BEATS: if (ddr_dout_ready) begin
                buf_mem[bw] <= ddr_dout;
                bw <= bw + 4'd1;
                if (bw == 4'(BURST - 1)) begin
                    ddr_own <= 1'b0;          // let the other masters in between bursts
                    waddr   <= waddr + 29'(BURST);
                    br <= '0; lane <= '0; wr_q <= 1'b0;
                    st <= S_EMIT;
                end
            end
            S_EMIT: begin
                wr_q <= 1'b0;
                if (next_addr >= len) st <= S_DONE;
                else if (!ld_wait && !wr_q && !ld_wr) begin
                    ld_wr     <= 1'b1;
                    wr_q      <= 1'b1;
                    ld_addr   <= next_addr;
                    ld_dout   <= cur[16 * lane +: 16];
                    next_addr <= next_addr + 27'd2;
                    lane      <= lane + 2'd1;
                    if (lane == 2'd3) begin
                        br <= br + 4'd1;
                        if (br == 4'(BURST - 1)) st <= S_REQ;
                    end
                end
            end
            S_DONE: if (!ld_wait && !ld_wr) begin
                ld_download <= 1'b0;
                loads <= loads + 32'd1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
