module atarigt_inputs
(
	input  [31:0] joystick_0,
	input  [31:0] joystick_1,
	input         set_jan,
	input         tmek,

	// hps_io analog sticks, [15:8]=Y [7:0]=X, signed -127..127 (sys/hps_io.sv:48-50)
	input  [15:0] joystick_l_analog_0,
	input  [15:0] joystick_r_analog_0,
	input         stick_modern, // left stick moves and strafes, right stick X turns
	input         stick_swap,
	input         service_mode, // test menu: handles as in Arcade, Modern doubles X steps

	output [31:0] p1p2,
	output [15:0] coin,
	output [31:0] analog
);

// primrageo (Dec 1994): no start bits, buttons 1-4 fill the start/button1-3
// slots of the common port at bits 8-11 (P2) and 24-27 (P1); the game starts
// on button 1 (High Quick) as on the cabinet, so the pad Start is not used
wire [31:0] p1p2_dec;
assign p1p2_dec[7:0]   = 8'hff;
assign p1p2_dec[8]     = ~joystick_1[4];
assign p1p2_dec[9]     = ~joystick_1[5];
assign p1p2_dec[10]    = ~joystick_1[6];
assign p1p2_dec[11]    = ~joystick_1[7];
assign p1p2_dec[12]    = ~joystick_1[0];
assign p1p2_dec[13]    = ~joystick_1[1];
assign p1p2_dec[14]    = ~joystick_1[2];
assign p1p2_dec[15]    = ~joystick_1[3];
assign p1p2_dec[23:16] = 8'hff;
assign p1p2_dec[24]    = ~joystick_0[4];
assign p1p2_dec[25]    = ~joystick_0[5];
assign p1p2_dec[26]    = ~joystick_0[6];
assign p1p2_dec[27]    = ~joystick_0[7];
assign p1p2_dec[28]    = ~joystick_0[0];
assign p1p2_dec[29]    = ~joystick_0[1];
assign p1p2_dec[30]    = ~joystick_0[2];
assign p1p2_dec[31]    = ~joystick_0[3];

// primrage (Jan 1995): common port unmodified except a dedicated start at
// bit 8/24 and button4 pulled out to bit 1 (P1) / bit 3 (P2)
wire [31:0] p1p2_jan;
assign p1p2_jan[0]     = 1'b1;
assign p1p2_jan[1]     = ~joystick_0[7];
assign p1p2_jan[2]     = 1'b1;
assign p1p2_jan[3]     = ~joystick_1[7];
assign p1p2_jan[7:4]   = 4'hf;
assign p1p2_jan[8]     = ~joystick_1[9];
assign p1p2_jan[9]     = ~joystick_1[4];
assign p1p2_jan[10]    = ~joystick_1[5];
assign p1p2_jan[11]    = ~joystick_1[6];
assign p1p2_jan[12]    = ~joystick_1[0];
assign p1p2_jan[13]    = ~joystick_1[1];
assign p1p2_jan[14]    = ~joystick_1[2];
assign p1p2_jan[15]    = ~joystick_1[3];
assign p1p2_jan[23:16] = 8'hff;
assign p1p2_jan[24]    = ~joystick_0[9];
assign p1p2_jan[25]    = ~joystick_0[4];
assign p1p2_jan[26]    = ~joystick_0[5];
assign p1p2_jan[27]    = ~joystick_0[6];
assign p1p2_jan[28]    = ~joystick_0[0];
assign p1p2_jan[29]    = ~joystick_0[1];
assign p1p2_jan[30]    = ~joystick_0[2];
assign p1p2_jan[31]    = ~joystick_0[3];

// T-MEK (MAME atarigt.cpp common INPUT_PORTS): one seat, P1/P2 buttons 1-2 are the
// right/left trigger and thumb on one pad; the service test shows no button 3,
// button4, start2 or P2 d-pad, so those stay released
wire [31:0] p1p2_tm = {p1p2_jan[31:28], 1'b1, p1p2_jan[26:12], 1'b1, ~joystick_0[7], ~joystick_0[6], 1'b1, 8'hff};
assign p1p2 = tmek ? p1p2_tm | 32'h0000_f000 : (set_jan ? p1p2_jan : p1p2_dec);

// coin port is the same "COIN" region in both sets: bit7 = COINL (P1), bit6 = COINR (P2)
assign coin = {8'hff, ~joystick_0[8], ~joystick_1[8], 6'h3f};

// One T-MEK board is one seat, so MAME P1/P2 are its right/left handles (service
// menu stick test): right = ch7/ch6 (AN3 X, AN2 Y), left = ch3/ch2 (AN1 X, AN4 Y);
// handle forward = low byte, so the right handle alone forward turns left
function automatic signed [9:0] sat127(input signed [9:0] v);
	sat127 = (v > 10'sd127) ? 10'sd127 : (v < -10'sd127) ? -10'sd127 : v;
endfunction

wire signed [9:0] lx = {{2{joystick_l_analog_0[7]}},  joystick_l_analog_0[7:0]};
wire signed [9:0] ly = {{2{joystick_l_analog_0[15]}}, joystick_l_analog_0[15:8]};
wire signed [9:0] rx = {{2{joystick_r_analog_0[7]}},  joystick_r_analog_0[7:0]};
wire signed [9:0] ry = {{2{joystick_r_analog_0[15]}}, joystick_r_analog_0[15:8]};

// forward/turn drive both handles: AN2 = -(fwd - turn), AN4 = -(fwd + turn); the
// d-pad does this while every stick axis rests (pads without sticks)
wire signed [9:0] dy = (joystick_0[3] ? 10'sd127 : 10'sd0) - (joystick_0[2] ? 10'sd127 : 10'sd0);
wire signed [9:0] dt = (joystick_0[0] ? 10'sd127 : 10'sd0) - (joystick_0[1] ? 10'sd127 : 10'sd0);
wire rest = (lx < 10'sd16) && (lx > -10'sd16) && (ly < 10'sd16) && (ly > -10'sd16) &&
            (rx < 10'sd16) && (rx > -10'sd16) && (ry < 10'sd16) && (ry > -10'sd16);
wire dpad = rest && (dy != 10'sd0 || dt != 10'sd0);
wire modern = stick_modern & ~service_mode;

wire signed [9:0] a3 = dpad ? 10'sd0     : modern ? lx : rx;
wire signed [9:0] a2 = dpad ? dt - dy    : modern ? ly + rx : ry;
wire signed [9:0] a1 = dpad ? 10'sd0     : lx;
wire signed [9:0] a4 = dpad ? -(dy + dt) : modern ? ly - rx : ly;

wire signed [9:0] an3 = sat127(stick_swap ? a1 : a3);
wire signed [9:0] an2 = sat127(stick_swap ? a4 : a2);
wire signed [9:0] an1 = sat127(stick_swap ? a3 : a1);
wire signed [9:0] an4 = sat127(stick_swap ? a2 : a4);

assign analog[31:24] = an3[7:0] ^ 8'h80; // ch7: AN3
assign analog[23:16] = an2[7:0] ^ 8'h80; // ch6: AN2
assign analog[15:8]  = an1[7:0] ^ 8'h80; // ch3: AN1
assign analog[7:0]   = an4[7:0] ^ 8'h80; // ch2: AN4

endmodule
