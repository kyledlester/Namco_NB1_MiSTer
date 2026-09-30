//============================================================================
//
//  Namco NB-1 MiSTer core -- top level (emu).
//  Copyright (C) 2026 Kyle Lester
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  Structure follows MiSTer-devel/Template_MiSTer (Template.sv, GPL-2.0+).
//
//============================================================================
//
// M1 skeleton: PLL (96.768 MHz clk_sys), NB-1 clock enables, reset tree,
// NB-1 raster (384x264 @ 6.048 MHz, 288x224 active) and a test pattern.
// M2: MRA ROM download into SDRAM through the logical memory front end
// (nb1_memory), plus a read-back checker whose status is overlaid on the
// test pattern.
// M3: the 68EC020 (TG68K, nb1_cpu) runs the real program from region PROG
// through nb1_main_bus (program line buffer, CPU RAMs; every other NB-1
// device is unimplemented and logged), with the SR-2 credit scheduler and a
// diagnostic overlay. No video, sound, C75 or I/O device is emulated.
// M4/M5: CPU-visible C116 palette storage and C123 tile VRAM inside
// nb1_main_bus (CPU storage only; nothing is rendered from them yet).
// M6: CPU-visible 2816 parallel EEPROM inside nb1_main_bus.
// M18: EEPROM persistence through MiSTer NVRAM (nb1_nvram, ioctl index 1;
// docs/M18_IMPLEMENTATION.md).
// M9: main-CPU VBL interrupt: nb1_main_irq (inside nb1_main_bus) raises the
// programmed level at vblank_begin (start of line 224) and nb1_cpu delivers
// it to the TG68K as an autovectored interrupt.
// M10: first picture: C123 control registers, the C123 tile line renderer
// (nb1_c123_render: VRAM video port, SHAPE cache, CHR/SHAPE reads from SDRAM
// as the lowest-priority nb1_memory client) and the C116 output stage
// (nb1_video_out: palette video port, clip window). No sprites, no POS
// raster interrupt. OSD: debug overlay or game picture; game or test pattern
// background.
// M11: C355 sprites: sprite RAM/position/bank (nb1_c355_ram in nb1_main_bus),
// nb1_c355_render (vblank snapshot, line renderer, OBJ reads as the
// lowest-priority nb1_memory client 5) and the sprite/tile mixer in
// nb1_video_out.
// M14: player controls (nb1_inputs -> the C75 ports; the C75 firmware passes
// them to the game through shared RAM, as on the PCB).
// M13: POS raster interrupt (nb1_main_irq) and per-line raster effects: every
// CPU-facing raster event (CPU release, VBL, POS line compare, C355
// position/bank latch) runs on the CPU raster = video raster + 2 lines
// (nb1_cpu_raster), so the unchanged tile renderer samples line T's C123
// state at the start of CPU line T+1 (docs/M13_RESEARCH.md); the C116 clip
// registers travel with each tile line (nb1_video_out). Video timing is
// unchanged.
// See docs/M1_IMPLEMENTATION.md .. docs/M13_IMPLEMENTATION.md.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// SDRAM is driven by rtl/vendor/sdram.sv (below). DDR3 is driven only by the
// framework's screen_rotate framebuffer (M16, VIDEO below; MISTER_FB).

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Audio (M15): the C352's front L/R at 84 kHz (below), signed; AUDIO_MIX = OSD stereo mix.
assign AUDIO_S = 1;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// Native NB-1 raster (unrotated): 288x224 on a 4:3 horizontal display.
// M16: Original = 4:3, or 3:4 while the HDMI picture is turned 90 degrees
// (Orientation Vertical CW/CCW, VIDEO below); Full Screen / ARC as before.
wire [1:0] ar = status[122:121];
wire       video_rotated;

assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
// OSD (M16 order: video, orientation/controls, board switches, audio,
// diagnostics, actions; J1/jn/v/V last -- the NA-1/NA-2 CONF_STR entry-order
// lesson). Status bits (docs/M16_IMPLEMENTATION.md): 0 Reset, 1 Re-run ROM
// check, (2 Display, 3 Background: removed in M21), 4 Program cache, 5 Service mode, (6 Freeze, 7 Test switch,
// 8 Controls: removed in M22 -- reserved, never reused, so saved settings keep their meaning),
// 10:9 Stereo mix, 12:11 Scandoubler Fx (M16),
// 14:13 Orientation (M16), 15 Sprite zoom (M21: 0 Continuous, 1 MAME), 122:121 Aspect ratio; M17 CRT Adjust, the NA-1/NA-2
// bits and encodings: 96 On, 104:101 H-Position, 108:105 V-Shift, 116:112
// H-Size (nb1_crt_adjust.sv). The P1 submenu hides the amounts (H1 = menumask
// bit 1) while CRT Adjust is Off. The M16 bits were never used
// before, so saved settings keep their meaning (v unchanged). M22: the controls
// always follow the game orientation (the former Controls = Game).
localparam CONF_STR = {
	"NB1;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[12:11],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"-;",
	"O[14:13],Orientation,Horizontal,Vertical CCW,Vertical CW,Flipped;",
	"O[15],Sprite zoom,Continuous,MAME;",
	"-;",
	"P1,CRT Adjust;",
	"P1O[96],CRT Adjust,Off,On;",
	"H1P1O[116:112],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[104:101],CRT H-Position,0,+6,+12,+18,+24,+30,+36,+42,-48,-42,-36,-30,-24,-18,-12,-6;",
	"H1P1O[108:105],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[5],Service mode (SW1-1),Off,On;",
	"-;",
	"O[10:9],Stereo mix,None,25%,50%,100%;",
	"-;",
	"O[4],Program cache,On,Off (M11 2-line);",
	"-;",
	"T[0],Reset;",
	"T[1],Re-run ROM check;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Button 1,Button 2,Button 3,Start,Coin,Service;",
	"jn,A,B,X,Start,Select,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

// ioctl indices (MRA <rom index=...>). See docs/M2_IMPLEMENTATION.md section 5.
//   0 = ROM stream (fixed platform layout, nb1_mem_pkg)
//   2 = board configuration record (M7: KEYCUS part description; nb1_board_config)
//   3 = M2 check record (diagnostic; expected CRC32s, generated from MAME metadata)
//   1 = EEPROM image (M18): the MRA's erased/default image, then the saved .nvm
//       (<nvram index="1" size="2048"/>); uploads on index 1 save it (nb1_nvram)
localparam [15:0] IOCTL_ROM   = 16'd0;
localparam [15:0] IOCTL_NVRAM = 16'd1;
localparam [15:0] IOCTL_BOARD = 16'd2;
localparam [15:0] IOCTL_CHECK = 16'd3;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wait;
wire        ld_ioctl_wait;       // ROM loader (index 0)
wire        ioctl_upload, ioctl_rd, nv_upload_req, nv_ioctl_wait;
wire [15:0] ioctl_din;
assign ioctl_wait = ld_ioctl_wait | nv_ioctl_wait;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.buttons(buttons),
	.status(status),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.status_menumask({14'd0, ~status[96], 1'b0}),   // M17: H1 = CRT Adjust amounts, hidden while Off

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_upload_req),
	.ioctl_upload_index(IOCTL_NVRAM[7:0]),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;      // 96.768 MHz = 2 x 48.384 MHz NB-1 master oscillator
wire pll_locked;

nb1_pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.clk_sys(clk_sys),
	.locked(pll_locked)
);

wire       ce_xtal, ce_cpu, ce_c352, ce_c75, ce_pix;
wire [5:0] ce_phase;

nb1_clock_enables clock_enables
(
	.clk_sys(clk_sys),
	.ce_xtal(ce_xtal),
	.ce_cpu(ce_cpu),
	.ce_c352(ce_c352),
	.ce_c75(ce_c75),
	.ce_pix(ce_pix),
	.phase(ce_phase)
);

///////////////////////   RASTER   ///////////////////////////////

wire [8:0] hcount, vcount, c116_h, c116_v;
wire       hblank, vblank, de, hsync, vsync;
wire       line_end, frame_end, vblank_begin;

nb1_video_timing video_timing
(
	.clk_sys(clk_sys),
	.ce_pix(ce_pix),
	.hcount(hcount),
	.vcount(vcount),
	.c116_h(c116_h),
	.c116_v(c116_v),
	.hblank(hblank),
	.vblank(vblank),
	.de(de),
	.hsync(hsync),
	.vsync(vsync),
	.line_end(line_end),
	.frame_end(frame_end),
	.vblank_begin(vblank_begin)
);

// M13: CPU-facing raster events, 2 lines ahead of the video raster.
wire       cpu_line_start, cpu_vbl, cpu_frame;
wire [8:0] cpu_line_next;
nb1_cpu_raster #(.LEAD(2)) cpu_raster
(
	.line_end(line_end),
	.vcount(vcount),
	.line_start(cpu_line_start),
	.line_next(cpu_line_next),
	.vbl(cpu_vbl),
	.frame(cpu_frame)
);

///////////////////////   RESET   ////////////////////////////////

wire reset_sys, reset_cpu, reset_c75, reset_video;

nb1_reset reset_gen
(
	.clk_sys(clk_sys),
	.reset_request(RESET | status[0] | buttons[1] | ioctl_download),   // M2: devices held during any download
	.pll_locked(pll_locked),
	.frame_end(frame_end),
	.reset_sys(reset_sys),
	.reset_cpu(reset_cpu),
	.reset_c75(reset_c75),
	.reset_video(reset_video)
);

///////////////////////   ROM / MEMORY (M2)   ////////////////////
//
// Memory, controller and loader are reset only by PLL loss of lock (the
// same condition that re-initialises the SDRAM). OSD/user resets and
// downloads never reset them, so loaded data and loader state survive.

wire mem_init = ~pll_locked;

// 0 = ROM loader, 1 = CPU main bus (M3), 2 = ROM checker, 3 = C75 data ROM
// (M8), 4 = C123 tile renderer CHR/SHAPE reads (M10), 5 = C355 sprite
// renderer OBJ reads (M11; below the tiles, which have the tighter
// one-line deadline). Fixed priority, lowest
// index first. The CPU only starts after the checker has finished (cpu_go
// below), so they compete only on an OSD "Re-run ROM check"; the C75 runs
// only after the 68020 releases it; the renderer runs only while the CPU runs
// and always yields to every other client (docs/M10_RESEARCH.md section 7).
// LOW_HOLD(2): client 5 is not granted in the 2 cycles after any other
// client's response, so the tile renderer keeps back-to-back reads and its
// line deadline under sprite load (docs/M11_IMPLEMENTATION.md section 9).
// Tile priority is absolute while a tile line is in progress: the sprite
// request is presented to the arbiter only when the tile renderer is not
// drawing (rnd_line_busy low); otherwise sprite reads slipped into the tile
// walker's short request gaps (SHAPE-miss / empty-row runs) and cost tile lines
// on hardware (section 9.10). The sprite client keeps its request stable and is
// granted later; the client contract is unchanged.
localparam int MEM_CLIENTS = 6;

// Program line buffer (nb1_main_bus): 2**M3_LINES_LOG2 lines of 8 bytes.
// The measurement behind the choice: docs/M3_RESEARCH.md section 6.
localparam int M3_LINES_LOG2 = 1;
// M12: 68020 program-ROM cache, 2**M12_PCACHE_LOG2 lines of 8 bytes in M10K
// (512 = 4 KiB, docs/M12_RESEARCH.md; 8 = 256 lines, 10 = 1,024 lines are
// rebuilds). It replaces the line buffer above; OSD "Program cache: Off"
// (status[4]) restricts it to the M3-M11 2-line geometry for A/B tests.
localparam int M12_PCACHE_LOG2 = 9;
reg pcache_bypass = 1'b0;
always @(posedge clk_sys) pcache_bypass <= status[4];

wire [MEM_CLIENTS-1:0]    mreq_valid, mreq_ready, mreq_we, mrsp_valid;
wire [MEM_CLIENTS*4-1:0]  mreq_region, mreq_be;
wire [MEM_CLIENTS*25-1:0] mreq_offset;
wire [MEM_CLIENTS*32-1:0] mreq_wdata;
wire [31:0]               mrsp_rdata;
wire [63:0]               mrsp_line;
wire                      mrsp_err;

wire        phy_req, phy_rnw, phy_ready;
wire [26:1] phy_addr;
wire [15:0] phy_din;
wire [1:0]  phy_be;
wire [63:0] phy_dout;

nb1_memory #(.CLIENTS(MEM_CLIENTS), .LOW_HOLD(2)) memory
(
	.clk_sys(clk_sys),
	.init(mem_init),
	.req_valid(mreq_valid),
	.req_ready(mreq_ready),
	.req_region(mreq_region),
	.req_offset(mreq_offset),
	.req_we(mreq_we),
	.req_wdata(mreq_wdata),
	.req_be(mreq_be),
	.rsp_valid(mrsp_valid),
	.rsp_rdata(mrsp_rdata),
	.rsp_line(mrsp_line),
	.rsp_err(mrsp_err),
	.phy_req(phy_req),
	.phy_rnw(phy_rnw),
	.phy_addr(phy_addr),
	.phy_din(phy_din),
	.phy_be(phy_be),
	.phy_ready(phy_ready),
	.phy_dout(phy_dout),
	.busy()
);

// Vendored MiSTer controller, same clock as clk_sys (no clock-domain crossing).
// Refresh: 64 ms / 8192 rows at 96.768 MHz -> 755 (docs/M2_RESEARCH.md SR-1).
sdram #(.CYCLES_PER_REFRESH(14'd755)) sdram
(
	.init(mem_init),
	.clk(clk_sys),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_CLK(SDRAM_CLK),
	.ch1_addr(phy_addr),
	.ch1_dout(phy_dout),
	.ch1_din(phy_din),
	.ch1_be(phy_be),
	.ch1_req(phy_req),
	.ch1_rnw(phy_rnw),
	.ch1_ready(phy_ready),
	.ch2_addr(26'd0),
	.ch2_dout(),
	.ch2_din(32'd0),
	.ch2_req(1'b0),
	.ch2_rnw(1'b1),
	.ch2_ready(),
	.ch3_addr(24'd0),
	.ch3_dout(),
	.ch3_din(16'd0),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_ready()
);

wire        rom_loading, rom_loaded;
wire [26:0] rom_stream_bytes;
wire        ld_err_overrun, ld_err_range, ld_err_write;

nb1_rom_loader #(.INDEX(IOCTL_ROM)) rom_loader
(
	.clk_sys(clk_sys),
	.init(mem_init),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ld_ioctl_wait),
	.req_valid(mreq_valid[0]),
	.req_ready(mreq_ready[0]),
	.req_region(mreq_region[3:0]),
	.req_offset(mreq_offset[24:0]),
	.req_we(mreq_we[0]),
	.req_wdata(mreq_wdata[31:0]),
	.req_be(mreq_be[3:0]),
	.rsp_valid(mrsp_valid[0]),
	.rsp_err(mrsp_err),
	.loading(rom_loading),
	.rom_loaded(rom_loaded),
	.stream_bytes(rom_stream_bytes),
	.err_overrun(ld_err_overrun),
	.err_range(ld_err_range),
	.err_write(ld_err_write)
);

wire        chk_record_ok, chk_running, chk_done, chk_all_pass, chk_length_ok;
wire [5:0]  chk_entry_count;
wire [63:0] chk_entry_status;
wire [3:0]  chk_run_count;

nb1_rom_check #(.INDEX(IOCTL_CHECK), .MAX_ENTRIES(32)) rom_check
(
	.clk_sys(clk_sys),
	.init(mem_init),
	.reset(reset_sys),
	.restart(status[1]),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.rom_loaded(rom_loaded),
	.stream_bytes(rom_stream_bytes),
	.req_valid(mreq_valid[2]),
	.req_ready(mreq_ready[2]),
	.req_region(mreq_region[11:8]),
	.req_offset(mreq_offset[74:50]),
	.req_we(mreq_we[2]),
	.req_wdata(mreq_wdata[95:64]),
	.req_be(mreq_be[11:8]),
	.rsp_valid(mrsp_valid[2]),
	.rsp_rdata(mrsp_rdata),
	.rsp_err(mrsp_err),
	.record_ok(chk_record_ok),
	.entry_count(chk_entry_count),
	.entry_status(chk_entry_status),
	.running(chk_running),
	.done(chk_done),
	.all_pass(chk_all_pass),
	.length_ok(chk_length_ok),
	.run_count(chk_run_count)
);

///////////////////////   C75 INTERNAL ROM (M8)   ////////////////
//
// The C75's 16 KiB internal BIOS (region C75BIOS, stream 0x1800000-0x1803FFF)
// is loaded into SDRAM by the M2 loader like every region. The C75 executes
// it from on-chip M10K instead, so the same ioctl words are also written
// there as they stream past (no SDRAM traffic for the BIOS; the M2 check
// still verifies the stream). WIDE=1: ioctl_dout = {byte 2k+1, byte 2k} =
// the little-endian C75 word.

wire c75_irom_we = ioctl_download && (ioctl_index == IOCTL_ROM) && ioctl_wr &&
                   (ioctl_addr >= 27'h1800000) && (ioctl_addr < 27'h1804000);

///////////////////////   BOARD CONFIGURATION (M7)   /////////////
//
// The MRA's board record (ioctl index 2) says which KEYCUS part is fitted
// and on which words it answers. Taken when its download ends, while the
// CPU is held in reset; forgotten only on PLL loss of lock or replaced by a
// new index-2 download. No record = KEYCUS answers $0000 everywhere.

wire        brd_ok, brd_seen;
wire [1:0]  brd_game_rot;   // M16: the game's MAME orientation (record v2; else ROT90)
wire [7:0]  kc_mode;
wire [3:0]  kc_id_word, kc_rnd_word;
wire [15:0] kc_id;

nb1_board_config #(.INDEX(IOCTL_BOARD)) board_config
(
	.clk_sys(clk_sys),
	.init(mem_init),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.record_ok(brd_ok),
	.record_seen(brd_seen),
	.kc_mode(kc_mode),
	.kc_id_word(kc_id_word),
	.kc_id(kc_id),
	.kc_rnd_word(kc_rnd_word),
	.game_rot(brd_game_rot)
);

///////////////////////   ORIENTATION (M16)   ////////////////////
//
// OSD Orientation -> the framework's screen_rotate (VIDEO below) and, with
// Controls = Match display, the stick rotation (nb1_inputs). Truth table and
// the reasons Flipped is framebuffer-only on the NB-1: nb1_orientation.sv.

wire       rot_no_rotate, rot_ccw, rot_flip, rot_native_flip;
wire [1:0] disp_q, ctl_rot_q;

nb1_orientation orientation
(
	.orient(status[14:13]),
	.direct_video(direct_video),
	.game_rot(brd_game_rot),
	.ctl_match(1'b0),        // M22: controls always follow the game orientation (OSD Controls removed; bit 8 reserved)
	.no_rotate(rot_no_rotate),
	.rotate_ccw(rot_ccw),
	.flip(rot_flip),
	.native_flip(rot_native_flip),
	.disp_q(disp_q),
	.rot_q(ctl_rot_q)
);

///////////////////////   68EC020 (M3)   /////////////////////////
//
// The CPU is released only when a ROM image is loaded and the M2 ROM check
// has finished (or no check record was supplied), and then only at a frame
// boundary like every other device reset (nb1_reset). So a bad ROM load is
// visible on the M2 panel before the CPU runs, the CPU never competes with
// the checker for SDRAM, and CPU time 0 is always CPU raster position (0,0)
// (M13: the start of CPU line 0 = video line 262).

reg cpu_go = 1'b0;
always @(posedge clk_sys) begin
	if (reset_cpu | ~rom_loaded)                                         cpu_go <= 1'b0;
	else if (cpu_frame && !chk_running && (chk_done || !chk_record_ok)) cpu_go <= 1'b1;
end
wire cpu_reset = reset_cpu | ~cpu_go;

wire        bc_start, bc_uds, bc_lds, bc_done;
wire [23:1] bc_addr;
wire [1:0]  bc_type;
wire [2:0]  bc_fc;
wire [15:0] bc_wdata, bc_rdata;
wire [2:0]  cpu_ipl;

wire        cpu_running;
wire [23:0] cpu_fetch_pc, cpu_steps_lf, cpu_earned_lf;
wire [31:0] cpu_vec_ssp, cpu_vec_pc, cpu_steps, cpu_bus_cycles, cpu_lost;
wire [1:0]  cpu_vec_seen;
wire [15:0] cpu_max_stall;
wire [31:0] cpu_stall_cycles;
wire [3:0]  cpu_cacr;
wire [31:0] cpu_vbr;
wire [5:0]  cpu_credit;

// MIN_GAP / SAMPLE_DELAY are timing contracts with NB1.sdc (see nb1_cpu.sv).
wire        pd_sample;   // M22 predecode (nb1_cpu -> nb1_main_bus)
wire [23:1] pd_addr;

nb1_cpu #(.MIN_GAP(3), .SAMPLE_DELAY(2), .CREDIT_MAX(32)) cpu
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.ce_cpu(ce_cpu),
	.frame_tick(frame_end),
	.ipl(cpu_ipl),
	.bc_start(bc_start),
	.bc_addr(bc_addr),
	.bc_type(bc_type),
	.bc_fc(bc_fc),
	.bc_uds(bc_uds),
	.bc_lds(bc_lds),
	.bc_wdata(bc_wdata),
	.bc_done(bc_done),
	.bc_rdata(bc_rdata),
	.pd_sample(pd_sample),
	.pd_addr(pd_addr),
	.running(cpu_running),
	.fetch_pc(cpu_fetch_pc),
	.vec_ssp(cpu_vec_ssp),
	.vec_pc(cpu_vec_pc),
	.vec_seen(cpu_vec_seen),
	.steps(cpu_steps),
	.bus_cycles(cpu_bus_cycles),
	.steps_last_frame(cpu_steps_lf),
	.earned_last_frame(cpu_earned_lf),
	.lost_credits(cpu_lost),
	.max_mem_stall(cpu_max_stall),
	.mem_stall_cycles(cpu_stall_cycles),
	.cacr(cpu_cacr),
	.vbr(cpu_vbr),
	.credit(cpu_credit)
);

wire [15:0] bus_cls_seen, bus_unimpl_wdata;
wire [31:0] bus_unimpl_reads, bus_unimpl_writes, bus_rom_writes, bus_ram_reads, bus_ram_writes;
wire [31:0] bus_c116_reads, bus_c116_writes;
wire [31:0] bus_c123_reads, bus_c123_writes;
wire [23:0] bus_last_c123;
wire        bus_last_c123_we;
wire [31:0] bus_eep_reads, bus_eep_writes;
wire [23:0] bus_last_eep;
wire        bus_last_eep_we;
wire [31:0] bus_kc_reads, bus_kc_writes;
wire [23:0] bus_last_kc;
wire        bus_last_kc_we;
wire [15:0] bus_last_kc_data;
wire        c75sh_en, c75sh_we;
wire [13:0] c75sh_addr;
wire [15:0] c75sh_wdata, c75sh_rdata;
wire [1:0]  c75sh_be;
wire        c75_run, c75_restart;
wire [7:0]  c75_ctl_writes;
wire [31:0] bus_line_hits, bus_line_misses;
wire [23:0] bus_first_unimpl, bus_last_unimpl_r, bus_last_unimpl_w;
wire        bus_first_unimpl_we, bus_first_unimpl_valid, bus_fill_error;
wire [3:0]  vbl_level;
wire        vbl_pending;
wire [31:0] vbl_events, vbl_raised, vbl_taken, vbl_acks, iack_cycles, pv_unr_count;
wire [3:0]  pos_level;
wire        pos_pending;
wire [8:0]  pos_frame, pos_ack_frame;
wire [15:0] pos_odd_frames;
wire [2:0]  last_iack_level;
wire        pv_unr_valid, pv_unw_valid;
wire [23:0] pv_unr_addr, pv_unw_addr;
wire [15:0] pv_unw_data;
wire [14:0] vid_vram_addr;
wire [15:0] vid_vram_data;
wire [12:0] vid_pen;
wire [23:0] vid_rgb;
wire [127:0] c116_regs;
wire [511:0] c123_ctl;
wire [14:0] obj_snap_addr;
wire [15:0] obj_snap_data;
wire [63:0] obj_pos;
wire [127:0] obj_bank;
wire        obj_capture;
wire [31:0] obj_unbacked, obj_writes;
wire [15:0] obj_holds;

// M18: EEPROM persistence (MiSTer NVRAM, ioctl index 1). It owns the
// EEPROM storage's second port; the CPU port and its timing are unchanged.
wire        nv_mem_en, nv_mem_we, eep_cpu_write;
wire [10:1] nv_mem_addr;
wire [15:0] nv_mem_wdata, nv_mem_rdata;
wire        nv_dirty;
wire [11:0] nv_events, nv_bytes;
wire [3:0]  nv_loads;
wire [7:0]  nv_saves;
wire [1:0]  nv_action;

nb1_nvram #(.INDEX(IOCTL_NVRAM), .BYTES(2048)) nvram
(
	.clk_sys(clk_sys),
	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(nv_ioctl_wait),
	.upload_req(nv_upload_req),
	.mem_en(nv_mem_en),
	.mem_we(nv_mem_we),
	.mem_addr(nv_mem_addr),
	.mem_wdata(nv_mem_wdata),
	.mem_rdata(nv_mem_rdata),
	.cpu_write(eep_cpu_write),
	.dirty(nv_dirty),
	.dirty_events(nv_events),
	.loads(nv_loads),
	.saves(nv_saves),
	.last_bytes(nv_bytes),
	.last_action(nv_action)
);

nb1_main_bus #(.LINES_LOG2(M3_LINES_LOG2), .PCACHE_LOG2(M12_PCACHE_LOG2), .PREDECODE(1'b1)) main_bus
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.pcache_bypass(pcache_bypass),
	.pd_sample(pd_sample),
	.pd_addr(pd_addr),
	.bc_start(bc_start),
	.bc_addr(bc_addr),
	.bc_type(bc_type),
	.bc_fc(bc_fc),
	.bc_uds(bc_uds),
	.bc_lds(bc_lds),
	.bc_wdata(bc_wdata),
	.bc_done(bc_done),
	.bc_rdata(bc_rdata),
	.mreq_valid(mreq_valid[1]),
	.mreq_ready(mreq_ready[1]),
	.mreq_region(mreq_region[7:4]),
	.mreq_offset(mreq_offset[49:25]),
	.mreq_we(mreq_we[1]),
	.mreq_wdata(mreq_wdata[63:32]),
	.mreq_be(mreq_be[7:4]),
	.mrsp_valid(mrsp_valid[1]),
	.mrsp_line(mrsp_line),
	.mrsp_err(mrsp_err),
	.c75sh_en(c75sh_en),
	.c75sh_we(c75sh_we),
	.c75sh_addr(c75sh_addr),
	.c75sh_wdata(c75sh_wdata),
	.c75sh_be(c75sh_be),
	.c75sh_rdata(c75sh_rdata),
	.c75_run(c75_run),
	.c75_restart(c75_restart),
	.c75_ctl_writes(c75_ctl_writes),
	.vbl_event(cpu_vbl),
	.ipl(cpu_ipl),
	.vbl_level(vbl_level),
	.vbl_pending(vbl_pending),
	.vbl_events(vbl_events),
	.vbl_raised(vbl_raised),
	.vbl_taken(vbl_taken),
	.vbl_acks(vbl_acks),
	.iack_cycles(iack_cycles),
	.last_iack_level(last_iack_level),
	.pos_event(cpu_line_start),
	.pos_line(cpu_line_next),
	.pos_level(pos_level),
	.pos_pending(pos_pending),
	.pos_raised(),
	.pos_taken(),
	.pos_acks(),
	.pos_frame(pos_frame),
	.pos_ack_frame(pos_ack_frame),
	.pos_odd_frames(pos_odd_frames),
	.pv_unr_valid(pv_unr_valid),
	.pv_unr_addr(pv_unr_addr),
	.pv_unw_valid(pv_unw_valid),
	.pv_unw_addr(pv_unw_addr),
	.pv_unw_data(pv_unw_data),
	.pv_unr_count(pv_unr_count),
	.nv_en(nv_mem_en),
	.nv_we(nv_mem_we),
	.nv_addr(nv_mem_addr),
	.nv_wdata(nv_mem_wdata),
	.nv_rdata(nv_mem_rdata),
	.eep_cpu_write(eep_cpu_write),
	.kc_cfg_valid(brd_ok),
	.kc_cfg_mode(kc_mode),
	.kc_cfg_id_word(kc_id_word),
	.kc_cfg_id(kc_id),
	.kc_cfg_rnd_word(kc_rnd_word),
	.vid_vram_addr(vid_vram_addr),
	.vid_vram_data(vid_vram_data),
	.vid_pen(vid_pen),
	.vid_rgb(vid_rgb),
	.c116_regs(c116_regs),
	.c123_ctl(c123_ctl),
	.c123_ctl_writes(),
	.obj_snap_addr(obj_snap_addr),
	.obj_snap_data(obj_snap_data),
	.obj_pos(obj_pos),
	.obj_bank(obj_bank),
	.obj_hold(obj_capture),
	.obj_unbacked_reads(obj_unbacked),
	.obj_writes(obj_writes),
	.obj_holds(obj_holds),
	.cls_seen(bus_cls_seen),
	.unimpl_reads(bus_unimpl_reads),
	.unimpl_writes(bus_unimpl_writes),
	.first_unimpl_addr(bus_first_unimpl),
	.first_unimpl_we(bus_first_unimpl_we),
	.first_unimpl_valid(bus_first_unimpl_valid),
	.last_unimpl_raddr(bus_last_unimpl_r),
	.last_unimpl_waddr(bus_last_unimpl_w),
	.last_unimpl_wdata(bus_unimpl_wdata),
	.rom_writes(bus_rom_writes),
	.ram_reads(bus_ram_reads),
	.ram_writes(bus_ram_writes),
	.c116_reads(bus_c116_reads),
	.c116_writes(bus_c116_writes),
	.c123_reads(bus_c123_reads),
	.c123_writes(bus_c123_writes),
	.last_c123_addr(bus_last_c123),
	.last_c123_we(bus_last_c123_we),
	.eep_reads(bus_eep_reads),
	.eep_writes(bus_eep_writes),
	.last_eep_addr(bus_last_eep),
	.last_eep_we(bus_last_eep_we),
	.kc_reads(bus_kc_reads),
	.kc_writes(bus_kc_writes),
	.last_kc_addr(bus_last_kc),
	.last_kc_we(bus_last_kc_we),
	.last_kc_data(bus_last_kc_data),
	.line_hits(bus_line_hits),
	.line_misses(bus_line_misses),
	.fill_error(bus_fill_error)
);

///////////////////////   C75 (M8)   ////////////////////////////
//
// Genuine C75: M37702 core (vendored from the NA-1 core) running c75.bin
// and the game's data ROM. Held in reset until the 68020 writes $400018 = 1;
// every such write restarts it and a write of 0 halts it (MAME cpureg_w).
// INT0/INT2: MAME's free-running 60 Hz sources (provisional, nb1_c75_irq).
// Inputs (M14): the MiSTer pads and OSD switches through nb1_inputs (below).

// M14: player controls -> the C75 input ports (P6/P7 and the P3 A-D inputs, nb1_c75);
// the C75 firmware passes them to the game in its shared-RAM mailbox (docs/M14_PLAN.md).
wire [7:0] in_p1, in_p2, in_p3, in_p4, in_misc;
nb1_inputs inputs
(
	.clk_sys(clk_sys),
	.joy0(joystick_0),
	.joy1(joystick_1),
	.joy2(joystick_2),
	.joy3(joystick_3),
	.sw_service_mode(status[5]),
	.sw_freeze(1'b0),        // M22: OSD Freeze screen removed (bit 6 reserved); SW1-2 off
	.sw_test(1'b0),          // M22: OSD Test switch removed (bit 7 reserved); Service mode covers it
	.rot_q(ctl_rot_q),  // M16: game orientation (board record) x display orientation x OSD Controls
	.p1(in_p1),
	.p2(in_p2),
	.p3(in_p3),
	.p4(in_p4),
	.misc(in_misc)
);

wire c75_irq0, c75_irq2;
wire [7:0] c75_ticks;
nb1_c75_irq c75_irq (.clk_sys(clk_sys), .irq0(c75_irq0), .irq2(c75_irq2), .ticks(c75_ticks));

wire        c75_running;
wire [23:0] c75_pc;
wire [31:0] c75_instr, c75_drom_reads, c75_drom_misses;
wire [15:0] c75_overruns, c75_int0, c75_int2, c75_max_wait, c75_c352w, c75_unmapped, c75_hs_a000, c75_hs_a0a0;
wire [7:0]  c75_hs_sets;

// M15: C352 sound. The C75 reaches its registers through the c352 port; its voice-ROM reads share the
// C75's nb1_memory client (3) through nb1_mem_mux2 (no arbiter change; ~1 read per video line).
wire        c75_mreq_valid, c75_mreq_ready, c75_mrsp_valid;
wire [3:0]  c75_mreq_region;
wire [24:0] c75_mreq_offset;
wire        c352_req, c352_we, c352_ack;
wire [10:0] c352_addr;
wire [1:0]  c352_be;
wire [15:0] c352_wdata, c352_rdata;
wire        snd_mreq_valid, snd_mreq_ready, snd_mrsp_valid;
wire [24:0] snd_mreq_offset;
wire [3:0]  snd_mreq_region;
wire signed [15:0] snd_l, snd_r;
wire [15:0] snd_overruns, snd_max_wait;
wire [31:0] snd_fetches;
wire [5:0]  snd_busy;

// 84,000 Hz = clk_sys / 1152 exactly (C352 clock 24.192 MHz / 288)
reg  [10:0] snd_div = 11'd0;
reg         snd_tick = 1'b0;
always @(posedge clk_sys) begin
	snd_tick <= (snd_div == 11'd1151);
	snd_div  <= (snd_div == 11'd1151) ? 11'd0 : snd_div + 11'd1;
end

nb1_c352 c352
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.sample_tick(snd_tick),
	.bus_req(c352_req),
	.bus_we(c352_we),
	.bus_addr(c352_addr),
	.bus_be(c352_be),
	.bus_wdata(c352_wdata),
	.bus_ack(c352_ack),
	.bus_rdata(c352_rdata),
	.mreq_valid(snd_mreq_valid),
	.mreq_ready(snd_mreq_ready),
	.mreq_offset(snd_mreq_offset),
	.mreq_region(snd_mreq_region),
	.mrsp_valid(snd_mrsp_valid),
	.mrsp_line(mrsp_line),
	.mrsp_err(mrsp_err),
	.out_l(snd_l),
	.out_r(snd_r),
	.out_valid(),
	.overruns(snd_overruns),
	.fetches(snd_fetches),
	.busy_voices(snd_busy),
	.max_wait(snd_max_wait)
);

nb1_mem_mux2 snd_mux
(
	.clk_sys(clk_sys),
	.a_valid(c75_mreq_valid),
	.a_ready(c75_mreq_ready),
	.a_region(c75_mreq_region),
	.a_offset(c75_mreq_offset),
	.a_rsp_valid(c75_mrsp_valid),
	.b_valid(snd_mreq_valid),
	.b_ready(snd_mreq_ready),
	.b_region(snd_mreq_region),
	.b_offset(snd_mreq_offset),
	.b_rsp_valid(snd_mrsp_valid),
	.m_valid(mreq_valid[3]),
	.m_ready(mreq_ready[3]),
	.m_region(mreq_region[15:12]),
	.m_offset(mreq_offset[99:75]),
	.m_rsp_valid(mrsp_valid[3])
);

assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = status[10:9];

// M15 overlay: the most BUSY voices in a frame and render overruns (row 23)
reg [5:0] snd_busy_max = 6'd0, snd_busy_frame = 6'd0;
always @(posedge clk_sys) begin
	if (frame_end) begin
		snd_busy_frame <= snd_busy_max;
		snd_busy_max   <= 6'd0;
	end else if (snd_busy > snd_busy_max) snd_busy_max <= snd_busy;
end

// M22 timing: the C75 hold/reset is registered once: it asserts and releases one clk_sys later than the
// combinational form (cpu_reset | ~c75_run | c75_restart), and every C75 flip-flop sees a register instead
// of the OR fanned out from cpu_go / the $400018 decode (docs/M22_TIMING_CLOSURE.md).
reg c75_reset_q = 1'b1;
always @(posedge clk_sys) c75_reset_q <= cpu_reset | ~c75_run | c75_restart;

nb1_c75 c75
(
	.clk_sys(clk_sys),
	.reset(c75_reset_q),   // M22: registered (was the combinational OR below, a reset fan-out path)
	.ce_c75(ce_c75),
	.irom_we(c75_irom_we),
	.irom_waddr(ioctl_addr[13:1]),
	.irom_wdata(ioctl_dout),
	.sh_en(c75sh_en),
	.sh_we(c75sh_we),
	.sh_addr(c75sh_addr),
	.sh_wdata(c75sh_wdata),
	.sh_be(c75sh_be),
	.sh_rdata(c75sh_rdata),
	.mreq_valid(c75_mreq_valid),
	.mreq_ready(c75_mreq_ready),
	.mreq_region(c75_mreq_region),
	.mreq_offset(c75_mreq_offset),
	.mreq_we(mreq_we[3]),
	.mreq_wdata(mreq_wdata[127:96]),
	.mreq_be(mreq_be[15:12]),
	.mrsp_valid(c75_mrsp_valid),
	.mrsp_line(mrsp_line),
	.mrsp_err(mrsp_err),
	.c352_req(c352_req),
	.c352_we(c352_we),
	.c352_addr(c352_addr),
	.c352_be(c352_be),
	.c352_wdata(c352_wdata),
	.c352_ack(c352_ack),
	.c352_rdata(c352_rdata),
	.irq0_in(c75_irq0),
	.irq2_in(c75_irq2),
	.in_p1(in_p1),
	.in_p2(in_p2),
	.in_p3(in_p3),
	.in_p4(in_p4),
	.in_misc(in_misc),
	.running(c75_running),
	.pc(c75_pc),
	.instr_count(c75_instr),
	.overrun_count(c75_overruns),
	.int0_count(c75_int0),
	.int2_count(c75_int2),
	.drom_reads(c75_drom_reads),
	.drom_misses(c75_drom_misses),
	.max_drom_wait(c75_max_wait),
	.c352_writes(c75_c352w),
	.unmapped_acc(c75_unmapped),
	.hs_sets(c75_hs_sets),
	.hs_a000(c75_hs_a000),
	.hs_a0a0(c75_hs_a0a0),
	.bus_req_o(), .bus_we_o(), .bus_addr_o(), .bus_be_o(), .bus_wdata_o(),
	.bus_ack_o(), .bus_rdata_o(), .irq_ack_o(), .irq_ack_line_o()
);

// Frames since the CPU started, and "no step during a whole frame".
reg [15:0] cpu_frames = 16'd0;
reg [31:0] cpu_steps_at_frame = 32'd0;
reg        cpu_stalled = 1'b0;
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		cpu_frames         <= 16'd0;
		cpu_stalled        <= 1'b0;
		cpu_steps_at_frame <= 32'd0;
	end else if (frame_end) begin
		cpu_frames         <= cpu_frames + 16'd1;
		cpu_stalled        <= (cpu_steps == cpu_steps_at_frame);
		cpu_steps_at_frame <= cpu_steps;
	end
end

// Overlay status: 0 held (no ROM), 1 held (ROM check / frame sync),
// 2 running, 3 running but no step in the last frame, 4 line-fill error.
wire [2:0] cpu_state = bus_fill_error ? 3'd4 :
                       !rom_loaded    ? 3'd0 :
                       !cpu_running   ? 3'd1 :
                       cpu_stalled    ? 3'd3 : 3'd2;

///////////////////////   C123 RENDERER + C116 OUTPUT (M10)   ////
//
// Line renderer: draws line N+1 of the six C123 layers while line N is shown
// (CHR/SHAPE from SDRAM, client 4), then nb1_video_out turns each line-buffer
// entry into RGB through the C116 palette video port and clip window. Held
// idle (and its SHAPE cache flushed) whenever the CPU is held, so the M2 ROM
// check never competes with it.

wire        rnd_disp_rd, rnd_disp_buf;
wire [8:0]  rnd_disp_x;
wire [15:0] rnd_disp_entry;
wire [5:0]  rnd_layers;
wire        rnd_flip, rnd_mem_error;
wire [15:0] rnd_chr, rnd_shape, rnd_worst, rnd_underruns;
wire        rnd_line_busy;   // tile line in progress (sprite requests wait)
wire        spr_mreq_valid;
wire [31:0] rnd_lines;

nb1_c123_render renderer
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.line_end(line_end),
	.vcount(vcount),
	.ctl(c123_ctl),
	.vram_addr(vid_vram_addr),
	.vram_data(vid_vram_data),
	.mreq_valid(mreq_valid[4]),
	.mreq_ready(mreq_ready[4]),
	.mreq_region(mreq_region[19:16]),
	.mreq_offset(mreq_offset[124:100]),
	.mreq_we(mreq_we[4]),
	.mreq_wdata(mreq_wdata[159:128]),
	.mreq_be(mreq_be[19:16]),
	.mrsp_valid(mrsp_valid[4]),
	.mrsp_line(mrsp_line),
	.mrsp_err(mrsp_err),
	.disp_rd(rnd_disp_rd),
	.disp_buf(rnd_disp_buf),
	.disp_x(rnd_disp_x),
	.disp_entry(rnd_disp_entry),
	.layer_mask(rnd_layers),
	.flip_out(rnd_flip),
	.chr_frame(rnd_chr),
	.shape_frame(rnd_shape),
	.worst_frame(rnd_worst),
	.underruns(rnd_underruns),
	.line_busy(rnd_line_busy),
	.lines_done(rnd_lines),
	.mem_error(rnd_mem_error)
);

// M11 tile-underrun diagnostic (overlay row 12): SDRAM transactions (counted on
// the registered response pulses, off the arbiter's grant path) per client in
// each line window (line_end to line_end); when the tile renderer abandons a
// line, the window that just ended (= that line's whole render time) is
// latched with the line number. Also the most CPU grants seen in one line.
reg  [8:0]  lw_cpu = '0, lw_tile = '0, ud_cpu = '0, ud_tile = '0, lw_last_cpu = '0, lw_last_tile = '0, ud_cpu_max = '0;
reg  [7:0]  lw_c75 = '0, lw_spr = '0, ud_c75 = '0, ud_spr = '0, lw_last_c75 = '0, lw_last_spr = '0;
reg  [7:0]  lw_last_line = '0, ud_line = '0;
reg  [15:0] ud_under_q = '0;
wire [8:0]  lw_next_line = (vcount == 9'd263) ? 9'd0 : vcount + 9'd1;
always @(posedge clk_sys) begin
	if (line_end) begin
		lw_last_cpu  <= lw_cpu;  lw_last_c75 <= lw_c75;  lw_last_tile <= lw_tile;  lw_last_spr <= lw_spr;
		lw_last_line <= lw_next_line[7:0];
		if (lw_cpu > ud_cpu_max) ud_cpu_max <= lw_cpu;
		lw_cpu <= '0; lw_c75 <= '0; lw_tile <= '0; lw_spr <= '0;
	end else begin
		if (mrsp_valid[1] && lw_cpu  != 9'h1FF) lw_cpu  <= lw_cpu  + 9'd1;
		if (mrsp_valid[3] && lw_c75  != 8'hFF)  lw_c75  <= lw_c75  + 8'd1;
		if (mrsp_valid[4] && lw_tile != 9'h1FF) lw_tile <= lw_tile + 9'd1;
		if (mrsp_valid[5] && lw_spr  != 8'hFF)  lw_spr  <= lw_spr  + 8'd1;
	end
	// the tile renderer counts an underrun on the clock after line_end
	ud_under_q <= rnd_underruns;
	if (rnd_underruns != ud_under_q) begin
		ud_line <= lw_last_line; ud_cpu <= lw_last_cpu; ud_c75 <= lw_last_c75;
		ud_tile <= lw_last_tile; ud_spr <= lw_last_spr;
	end
	if (cpu_reset) begin
		ud_line <= '0; ud_cpu <= '0; ud_c75 <= '0; ud_tile <= '0; ud_spr <= '0; ud_cpu_max <= '0;
		ud_under_q <= '0;
	end
end

// M11 closeout diagnostic: frames (vblank to vblank) in which the tile
// renderer abandoned at least one line (overlay row 8 `T`).
reg  [15:0] vid_under_frames = '0;
reg  [15:0] vid_under_last = '0;
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		vid_under_frames <= '0;
		vid_under_last   <= '0;
	end else if (vblank_begin) begin
		vid_under_last <= rnd_underruns;
		if (rnd_underruns != vid_under_last && vid_under_frames != 16'hFFFF)
			vid_under_frames <= vid_under_frames + 16'd1;
	end
end

// M13: the C355 position and bank registers are sampled at the CPU vblank
// (MAME: once per frame at vblank), before the VBL handler rewrites them;
// the sprite-RAM snapshot and the frame switch stay at the video vblank.
reg [63:0]  obj_pos_v = '0;
reg [127:0] obj_bank_v = '0;
always @(posedge clk_sys) if (cpu_vbl) begin
	obj_pos_v  <= obj_pos;
	obj_bank_v <= obj_bank;
end

wire        spr_rd;
assign mreq_valid[5] = spr_mreq_valid & ~rnd_line_busy;
wire [1:0]  spr_slot;
wire [8:0]  spr_x;
wire [15:0] spr_entry;
wire [8:0]  obj_count;
wire [12:0] obj_cells;
wire        obj_overflow, obj_mem_error;
wire [15:0] obj_drops, obj_fetch, obj_drop_frames;
wire [7:0]  obj_drop_max;

nb1_c355_render sprites
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.line_end(line_end),
	.vblank_begin(vblank_begin),
	.zoom_cont(~status[15]),       // M21: OSD "Sprite zoom", 0 = Continuous (default), 1 = MAME
	.vcount(vcount),
	.snap_addr(obj_snap_addr),
	.snap_data(obj_snap_data),
	.pos_in(obj_pos_v),
	.bank_in(obj_bank_v),
	.capture_busy(obj_capture),
	.mreq_valid(spr_mreq_valid),
	.mreq_ready(mreq_ready[5]),
	.mreq_region(mreq_region[23:20]),
	.mreq_offset(mreq_offset[149:125]),
	.mreq_we(mreq_we[5]),
	.mreq_wdata(mreq_wdata[191:160]),
	.mreq_be(mreq_be[23:20]),
	.mrsp_valid(mrsp_valid[5]),
	.mrsp_line(mrsp_line),
	.mrsp_err(mrsp_err),
	.disp_rd(spr_rd),
	.disp_slot(spr_slot),
	.disp_x(spr_x),
	.disp_entry(spr_entry),
	.spr_count(obj_count),
	.cell_count(obj_cells),
	.overflow(obj_overflow),
	.drops(obj_drops),
	.drop_frames(obj_drop_frames),
	.drop_max(obj_drop_max),
	.fetch_frame(obj_fetch),
	.mem_error(obj_mem_error)
);

wire [7:0] game_r, game_g, game_b;

nb1_video_out video_out
(
	.clk_sys(clk_sys),
	.ce_pix(ce_pix),
	.hcount(hcount),
	.vcount(vcount),
	.de(de),
	.line_end(line_end),
	.disp_rd(rnd_disp_rd),
	.disp_buf(rnd_disp_buf),
	.disp_x(rnd_disp_x),
	.disp_entry(rnd_disp_entry),
	.spr_rd(spr_rd),
	.spr_slot(spr_slot),
	.spr_x(spr_x),
	.spr_entry(spr_entry),
	.vid_pen(vid_pen),
	.vid_rgb(vid_rgb),
	.c116_regs(c116_regs),
	.r(game_r),
	.g(game_g),
	.b(game_b)
);

///////////////////////   TEST PATTERN   /////////////////////////

// Frames since the device-domain reset released. Cleared by reset_video,
// so an OSD reset visibly restarts the counter and marker.
reg [15:0] frame_count = 16'd0;
always @(posedge clk_sys) begin
	if (reset_video)    frame_count <= 16'd0;
	else if (frame_end) frame_count <= frame_count + 16'd1;
end

// M21 release: the M1 test pattern, the M2 ROM-check panel and the M3-M18 debug overlay are no longer
// instantiated (the owner's RC removes the Display / Background OSD options; the game picture always
// goes out). The modules stay in the repository for the benches (m9_overlay_tb etc.).
wire [7:0] m3_r = game_r, m3_g = game_g, m3_b = game_b;

///////////////////////   VIDEO (M16)   //////////////////////////
//
// The NB-1 raster (game picture + diagnostic overlay, unchanged native timing:
// 288x224 of 384x264 at clk_sys/16) goes through the framework's arcade_video
// (video_mixer: gamma, scandoubler with HQ2x / CRT scanline Fx, as on NA-1/NA-2)
// and screen_rotate (Orientation: DDR3 framebuffer -> HDMI scaler only). The
// overlay output is registered 3 clk after de/hblank/vblank, well inside the
// 16-clk pixel; arcade_video samples RGB and the blanks on the same ce_pix
// edge, exactly as the direct M1-M15 outputs were sampled.
//

// M17 native 15-kHz output: the bundle above IS the native NB-1 raster
// (MAME totals 384 x 264 at clk_sys/16 = 6.048 MHz: 15.750 kHz, 59.659 Hz,
// progressive; 288 x 224 active; HSync 32 px from pixel 310, VSync 3 lines
// from line 231; free-running, never reset). With Scandoubler Fx None and no
// forced scandoubler the framework passes it to the analog output unchanged;
// Direct Video carries it on HDMI. CRT Adjust (NA-1/NA-2 M26 behaviour,
// nb1_crt_adjust) reshapes only this outgoing stream: a true bypass while Off,
// gated off while the scandoubler is active, and never seen upstream.

// M17 native Flipped (nb1_native_flip): each finished frame goes to DDR3 and
// comes back one frame later bottom line first, each line right to left, on
// the unchanged native raster -- to the analog output, Direct Video and HDMI
// alike. The DDR3 port is shared with screen_rotate (Vertical CW/CCW, HDMI
// only): screen_rotate writes only while its FB_EN is high, and Flipped keeps
// it idle, so the flipper takes the port only while FB_EN is low.
wire [23:0] flip_rgb;
wire        flipping, flip_ddr;
wire [15:0] flip_late, flip_drops;
wire [7:0]  fl_burstcnt, sr_burstcnt;
wire [28:0] fl_addr, sr_addr;
wire [63:0] fl_din, sr_din;
wire [7:0]  fl_be, sr_be;
wire        fl_we, fl_rd, sr_we, sr_rd, sr_fb_en;

nb1_native_flip native_flip
(
	.clk_sys(clk_sys),
	.ce_pix(ce_pix),
	.hcount(hcount),
	.vcount(vcount),
	.de(de),
	.line_end(line_end),
	.frame_swap(vblank_begin),
	.rgb_in({m3_r, m3_g, m3_b}),
	.flip_req(rot_native_flip),
	.own(!sr_fb_en),
	.rgb_out(flip_rgb),
	.flipping(flipping),
	.ddr_active(flip_ddr),
	.late_lines(flip_late),
	.fifo_drops(flip_drops),
	.ddr_burstcnt(fl_burstcnt),
	.ddr_addr(fl_addr),
	.ddr_din(fl_din),
	.ddr_be(fl_be),
	.ddr_we(fl_we),
	.ddr_rd(fl_rd),
	.ddr_busy(DDRAM_BUSY),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY)
);

// the picture on the native raster: flipped while Flipped, else the M16 stream
wire [23:0] nat_rgb = flipping ? flip_rgb : {m3_r, m3_g, m3_b};

wire        av_ce, av_hb, av_vb, av_hs, av_vs;
wire [23:0] av_rgb;

nb1_crt_adjust crt_adjust
(
	.clk_sys(clk_sys),
	.ce_pix(ce_pix),
	.frame_event(frame_end),
	.osd_on(status[96]),
	.osd_hsize(status[116:112]),
	.osd_hpos(status[104:101]),
	.osd_vshift(status[108:105]),
	.sd_off((status[12:11] == 2'd0) && !forced_scandoubler),
	.vb_next((vcount == 9'd263) ? 1'b0 : (vcount >= 9'd223)),
	.rgb_in(nat_rgb),
	.hblank_in(hblank),
	.vblank_in(vblank),
	.hsync_in(hsync),
	.vsync_in(vsync),
	.ce_out(av_ce),
	.rgb_out(av_rgb),
	.hblank_out(av_hb),
	.vblank_out(av_vb),
	.hsync_out(av_hs),
	.vsync_out(av_vs),
	.active(),
	.hsize_s(),
	.hpos_s(),
	.vsh_s()
);

arcade_video #(.WIDTH(288), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(av_ce),
	.RGB_in(av_rgb),
	.HBlank(av_hb),
	.VBlank(av_vb),
	.HSync(av_hs),
	.VSync(av_vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),
	.fx({1'b0, status[12:11]}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Orientation (nb1_orientation): Vertical CW/CCW turn the HDMI picture 90
// degrees; the analog output keeps the native raster; Direct Video bypasses
// them. Flipped is native (above) and leaves screen_rotate idle.
screen_rotate screen_rotate
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.rotate_ccw(rot_ccw),
	.no_rotate(rot_no_rotate),
	.flip(rot_flip),
	.video_rotated(video_rotated),
	.FB_EN(sr_fb_en),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(sr_burstcnt),
	.DDRAM_ADDR(sr_addr),
	.DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be),
	.DDRAM_WE(sr_we),
	.DDRAM_RD(sr_rd)
);
assign FB_EN = sr_fb_en;
assign FB_FORCE_BLANK = 1'b0;
// DDR3: the flipper while it is flipping or finishing a transaction, else screen_rotate
assign DDRAM_BURSTCNT = flip_ddr ? fl_burstcnt : sr_burstcnt;
assign DDRAM_ADDR     = flip_ddr ? fl_addr     : sr_addr;
assign DDRAM_DIN      = flip_ddr ? fl_din      : sr_din;
assign DDRAM_BE       = flip_ddr ? fl_be       : sr_be;
assign DDRAM_WE       = flip_ddr ? fl_we       : sr_we;
assign DDRAM_RD       = flip_ddr ? fl_rd       : sr_rd;

// Disk LED: on while a ROM stream is being written.
assign LED_DISK = {1'b0, rom_loading};

// Heartbeat: toggles every 32 frames (about 0.9 Hz blink) while out of reset.
// M3: solid on while the CPU is held in reset, blinking once it runs.
assign LED_USER = cpu_running ? frame_count[5] : 1'b1;

endmodule
