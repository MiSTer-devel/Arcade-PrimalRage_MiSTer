module ddr_lat_meter #(parameter WIN_BITS = 25)
(
	input             clk,
	input             reset,
	input             rd_acc,
	input             dout_ready,

	output reg [63:0] win_q,
	output reg [63:0] max_q
);

// cycles from the accept cycle to the first dout_ready; the arbiter keeps one
// read outstanding at a time, so the next ready after an accept is its first word
reg        waiting;
reg [15:0] cnt;
reg [31:0] n, sum;
reg [15:0] mx, mn, mx_all;
reg [WIN_BITS-1:0] tick;

wire        done = waiting & dout_ready;
wire [31:0] n1   = n + done;
wire [31:0] sum1 = sum + (done ? {16'd0, cnt} : 32'd0);
wire [15:0] mx1  = (done && cnt > mx) ? cnt : mx;
wire [15:0] mn1  = (done && cnt < mn) ? cnt : mn;

always @(posedge clk) begin
	if (reset) begin
		waiting <= 0;
		cnt     <= 0;
		n       <= 0;
		sum     <= 0;
		mx      <= 0;
		mn      <= 16'hffff;
		mx_all  <= 0;
		tick    <= 0;
		win_q   <= 0;
		max_q   <= 0;
	end else begin
		tick <= tick + 1'd1;
		if (rd_acc) begin
			waiting <= 1;
			cnt     <= 1;
		end else if (done) begin
			waiting <= 0;
		end else if (waiting && cnt != 16'hffff) begin
			cnt <= cnt + 1'd1;
		end
		if (done) begin
			if (cnt > mx_all) mx_all <= cnt;
		end
		if (&tick) begin
			win_q <= {sum1, n1};
			max_q <= {mx_all, mx1, (mx1 == 0) ? 16'd0 : mn1, 16'h1a7c};
			n     <= 0;
			sum   <= 0;
			mx    <= 0;
			mn    <= 16'hffff;
		end else begin
			n   <= n1;
			sum <= sum1;
			mx  <= mx1;
			mn  <= mn1;
		end
	end
end

endmodule
