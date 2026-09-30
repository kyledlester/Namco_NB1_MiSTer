// NB-1 M22 bench: the HQ2x Blend clock-enable cadence on the NB-1 raster (evidence for the NB1.sdc
// multicycle on sys/hq2x.sv Blend). The framework scandoubler (sys/scandoubler.v, hq2x on) is driven by
// the production nb1_video_timing / ce_pix exactly as arcade_video feeds it (sim/m22_sd_ce_model.sv = the
// scandoubler's ce_x4i generator, verbatim) (the M17 CRT Adjust NCO is
// off whenever a scandoubler Fx is selected). Measured: the smallest distance, in clk_sys, between two
// ce_x4i pulses (= Hq2x ce_in = Blend clk_en), before and after the scandoubler has measured the pixel
// length, and whether any two pulses are ever on consecutive clocks after that.
`timescale 1ns/1ps
module m22_hq2x_ce_tb;
    reg clk = 1'b0;
    always #5.167 clk = ~clk;
    wire ce_xtal, ce_cpu, ce_c352, ce_c75, ce_pix; wire [5:0] ph;
    nb1_clock_enables ces (.clk_sys(clk), .ce_xtal(ce_xtal), .ce_cpu(ce_cpu), .ce_c352(ce_c352), .ce_c75(ce_c75),
                           .ce_pix(ce_pix), .phase(ph));
    wire [8:0] hc, vc, c116_h, c116_v; wire hb, vb, de, hs, vs, le, fe, vbb;
    nb1_video_timing vt (.clk_sys(clk), .ce_pix(ce_pix), .hcount(hc), .vcount(vc), .c116_h(c116_h), .c116_v(c116_v),
                         .hblank(hb), .vblank(vb), .de(de), .hsync(hs), .vsync(vs), .line_end(le), .frame_end(fe),
                         .vblank_begin(vbb));
    wire [7:0] pixsz;
    m22_sd_ce_model sd (.clk_vid(clk), .ce_pix(ce_pix), .hs_in(hs), .hb_in(hb), .vb_in(vb), .pixsz_o(pixsz));

    longint cyc = 0, last = -100, n = 0, n_locked = 0, consec_before = 0, consec_after = 0;
    int mind_before = 1000, mind_after = 1000;
    bit locked = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (!locked && pixsz != 0) begin locked = 1; $display("  pixel length measured at clk %0d: pixsz %0d", cyc, pixsz); end
        if (sd.ce_x4i) begin
            n++;
            if (cyc - last == 1) begin if (locked) consec_after++; else consec_before++; end
            if (locked) begin if (cyc - last < mind_after) mind_after = cyc - last; n_locked++; end
            else if (cyc - last < mind_before) mind_before = cyc - last;
            last = cyc;
        end
    end
    initial begin
        #(2 * 264 * 6144 * 10.334);
        $display("M22 HQ2x ce_in cadence on the NB-1 raster (2 frames)");
        $display("  before the pixel length is known: min spacing %0d clk, consecutive pairs %0d", mind_before, consec_before);
        $display("  after:  %0d pulses, min spacing %0d clk, consecutive pairs %0d", n_locked, mind_after, consec_after);
        if (consec_after == 0 && mind_after >= 2) $display("PASS M22 HQ2X CADENCE");
        else $display("FAIL M22 HQ2X CADENCE");
        $finish;
    end
endmodule
