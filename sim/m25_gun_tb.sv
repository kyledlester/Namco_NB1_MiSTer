// Namco NB-1 MiSTer core -- M25 bench: nb1_gun (light-gun I/O board model).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// 1. counts: for every joystick value (-128..127 on both axes of both sticks) the four counts equal
//    MAME gunbulet_state::gun_r with port = value + 128: X = 0x26 + port*288/314, Y = 0x0F + port*224/255
//    (8-bit, X wraps past $FF); with enable = 0 every count is 0.
// 2. mouse: player 1 follows accumulated mouse motion, clamped to 0..255; player 2 stays on stick 2.
// 3. crosshair: the centre pixel is transparent (target visible), the arm pixels 2..6 away are drawn in the
//    player's colour, nothing is drawn with cross_on = 0.
`timescale 1ns/1ps
module m25_gun_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg         enable = 1, src_mouse = 0, cross_on = 1;
    reg  [15:0] a0 = 0, a1 = 0;
    reg  [24:0] mouse = 0;
    reg  [8:0]  h = 0, v = 0;
    wire [31:0] counts;
    wire        hit;
    wire [23:0] rgb;
    int errors = 0;
    nb1_gun dut (.clk_sys(clk), .enable(enable), .src_mouse(src_mouse), .joy_a0(a0), .joy_a1(a1),
                 .ps2_mouse(mouse), .counts(counts), .cross_on(cross_on), .hcount(h), .vcount(v),
                 .cross_hit(hit), .cross_rgb(rgb));
    function automatic [7:0] ex(input int p); ex = 8'(8'h26 + p * 288 / 314); endfunction
    function automatic [7:0] ey(input int p); ey = 8'(8'h0F + p * 224 / 255); endfunction
    task automatic settle; repeat (4) @(posedge clk); endtask
    task automatic mouse_move(input int dx, input int dy);
        mouse[15:8] = 8'(dx); mouse[4] = dx < 0; mouse[23:16] = 8'(dy); mouse[5] = dy < 0;
        mouse[24] = ~mouse[24]; settle();
    endtask
    initial begin
        // 1. every stick value
        for (int x = -128; x < 128; x++) begin
            a0 = {8'(x), 8'(x)};                  // Y = X = x for player 1
            a1 = {8'(-1 - x), 8'(-1 - x)};        // the mirror value for player 2
            settle();
            if (counts[31:24] != ex(x + 128) || counts[23:16] != ey(x + 128) ||
                counts[15:8] != ex(127 - x) || counts[7:0] != ey(127 - x)) begin
                errors++;
                if (errors < 10) $display("ERROR value %0d: counts %08x expected %02x%02x%02x%02x", x, counts,
                                          ex(x + 128), ey(x + 128), ex(127 - x), ey(127 - x));
            end
        end
        enable = 0; settle();
        if (counts != 0) begin errors++; $display("ERROR counts %08x with no gun board", counts); end
        enable = 1;
        // 2. mouse: start at 128, +100 -> 228, +100 -> clamp 255, -300 -> 0; Y moves the other way (screen down)
        src_mouse = 1; a0 = 16'h0000; a1 = 16'h7F80;   // stick 2 at X = -128 (port 0), Y = 127 (port 255)
        mouse_move(100, -20);
        if (counts[31:24] != ex(228) || counts[23:16] != ey(148)) begin errors++; $display("ERROR mouse 1: %08x", counts); end
        mouse_move(100, 0);
        if (counts[31:24] != ex(255)) begin errors++; $display("ERROR mouse clamp high: %08x", counts); end
        mouse_move(-127, 127); mouse_move(-127, 127); mouse_move(-127, 0);
        if (counts[31:24] != ex(0) || counts[23:16] != ey(0)) begin errors++; $display("ERROR mouse clamp low: %08x", counts); end
        if (counts[15:8] != ex(0) || counts[7:0] != ey(255)) begin errors++; $display("ERROR stick 2 with mouse: %08x", counts); end
        // 3. crosshair: player 1 stick at port (128, 128) -> pixel (144, 112)
        src_mouse = 0; a0 = 16'h0000; a1 = 16'h8080;   // player 2 at port (0, 0) -> pixel (0, 0)
        settle();
        h = 144; v = 112; settle();
        if (hit) begin errors++; $display("ERROR crosshair centre drawn"); end
        h = 148; v = 112; settle();
        if (!hit || rgb != 24'hFF2020) begin errors++; $display("ERROR crosshair arm: hit %b rgb %06x", hit, rgb); end
        h = 144; v = 107; settle();
        if (!hit || rgb != 24'hFF2020) begin errors++; $display("ERROR crosshair arm (up): hit %b rgb %06x", hit, rgb); end
        h = 160; v = 112; settle();
        if (hit) begin errors++; $display("ERROR crosshair too wide"); end
        h = 4; v = 0; settle();
        if (!hit || rgb != 24'h2060FF) begin errors++; $display("ERROR player 2 crosshair: hit %b rgb %06x", hit, rgb); end
        cross_on = 0; h = 148; v = 112; settle();
        if (hit) begin errors++; $display("ERROR crosshair drawn while off"); end
        if (errors == 0) $display("PASS M25 GUN: 256 x 4 counts = MAME gun_r, mouse clamp, crosshair");
        else             $display("FAIL M25 GUN: %0d errors", errors);
        $finish;
    end
endmodule
