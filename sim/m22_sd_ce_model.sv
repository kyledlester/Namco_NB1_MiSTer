// NB-1 M22 bench model: the ce_x4i generator of the framework scandoubler (sys/scandoubler.v lines 51-91,
// COPIED VERBATIM). ModelSim 10.5b cannot compile the whole file (forward references). ce_x4i is the Hq2x
// ce_in, i.e. the Blend clk_en that the NB1.sdc HQ2x multicycle relies on.
module m22_sd_ce_model (
	input clk_vid, input ce_pix, input hs_in, input hb_in, input vb_in,
	output reg [7:0] pixsz_o
);
reg  [7:0] pix_len = 0;
wire [7:0] pl = pix_len + 1'b1;

reg  [7:0] pix_in_cnt = 0;
wire [7:0] pc_in = pix_in_cnt + 1'b1;
reg  [7:0] pixsz, pixsz2, pixsz4 = 0;

reg ce_x4i, ce_x1i;
always @(posedge clk_vid) begin
	reg old_ce, valid, hs;

	if(~&pix_len) pix_len <= pl;
	if(~&pix_in_cnt) pix_in_cnt <= pc_in;

	ce_x4i <= 0;
	ce_x1i <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_in == pixsz4) || (pc_in == pixsz2) || (pc_in == (pixsz2+pixsz4))) ce_x4i <= 1;

	old_ce <= ce_pix;
	if(~old_ce & ce_pix) begin
		if(valid & ~hb_in & ~vb_in) begin
			pixsz  <= pl;
			pixsz2 <= {1'b0,  pl[7:1]};
			pixsz4 <= {2'b00, pl[7:2]};
		end
		pix_len <= 0;
		valid <= 1;
	end

	hs <= hs_in;
	if((~hs & hs_in) || (pc_in >= pixsz)) begin
		ce_x4i <= 1;
		ce_x1i <= 1;
		pix_in_cnt <= 0;
	end

	if(hb_in | vb_in) valid <= 0;
end

always @* pixsz_o = pixsz;
endmodule
