module rom_ddr_replay #(parameter [28:0] STAGE_QBASE = 29'h07000000) // 0x38000000 >> 3, must equal the MRA rom address
(
	input             clk,
	input             reset,

	input             ioctl_download,
	input      [15:0] ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	output            ld_download,
	output     [15:0] ld_index,
	output            ld_wr,
	output     [26:0] ld_addr,
	output      [7:0] ld_dout,
	input             ld_wait,
	input             ld_ddr_pending,

	output            rom_download,

	output reg [28:0] ddr_addr,
	output            ddr_rd,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	input             ddr_busy
);

localparam [1:0] IDLE = 2'd0, REQ = 2'd1, WAIT = 2'd2, EMIT = 2'd3;

reg  [1:0] state;
reg        dl0_d, wr_seen, rd_q, emit_valid_q;
reg [26:0] len, offset;
reg [63:0] word;

wire dl0         = ioctl_download & (ioctl_index[7:0] == 8'd0);
wire idle        = (state == IDLE);
wire start       = dl0_d & ~dl0 & ~wr_seen & (len != 27'd0) & idle;
wire replay_side = start | ~idle;
wire [26:0] offset_n = offset + 27'd1;

assign rom_download = dl0 | replay_side;
assign ld_download  = replay_side ? 1'b1  : ioctl_download;
assign ld_index     = replay_side ? 16'd0 : ioctl_index;
assign ld_wr        = replay_side ? (emit_valid_q & ~ld_wait) : ioctl_wr;
assign ld_addr      = replay_side ? offset : ioctl_addr;
assign ld_dout      = replay_side ? word[{offset[2:0], 3'b000} +: 8] : ioctl_dout;
assign ioctl_wait   = replay_side ? 1'b0 : ld_wait;

// a loader DDR write can sit under waitrequest below this read in the arbiter;
// rd rises only with none pending so it never displaces that write
assign ddr_rd = (state == REQ) & (rd_q | ~ld_ddr_pending);

always @(posedge clk) begin
	if (reset) begin
		state        <= IDLE;
		dl0_d        <= 1'b0;
		wr_seen      <= 1'b0;
		rd_q         <= 1'b0;
		emit_valid_q <= 1'b0;
		len          <= 27'd0;
		offset       <= 27'd0;
		word         <= 64'd0;
		ddr_addr     <= STAGE_QBASE;
	end else begin
		dl0_d <= dl0;
		// hps_io holds the length in ioctl_addr for the whole window and adds 1 as download falls
		if (dl0) len <= ioctl_addr;
		if (dl0 & ~dl0_d) wr_seen <= 1'b0;
		if (dl0 & ioctl_wr) wr_seen <= 1'b1;

		case (state)
		IDLE:
			if (start) begin
				offset   <= 27'd0;
				ddr_addr <= STAGE_QBASE;
				state    <= REQ;
			end
		REQ:
			if (ddr_rd) begin
				if (~ddr_busy) begin
					rd_q  <= 1'b0;
					state <= WAIT;
				end else
					rd_q <= 1'b1;
			end
		WAIT:
			if (ddr_dout_ready) begin
				word         <= ddr_dout;
				emit_valid_q <= 1'b1;
				state        <= EMIT;
			end
		EMIT:
			if (ld_wr) begin
				offset <= offset_n;
				if (offset_n == len) begin
					emit_valid_q <= 1'b0;
					state        <= IDLE;
				end else if (&offset[2:0]) begin
					emit_valid_q <= 1'b0;
					ddr_addr     <= ddr_addr + 29'd1;
					state        <= REQ;
				end
			end
		endcase
	end
end

endmodule
