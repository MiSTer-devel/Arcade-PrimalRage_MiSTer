module xga_prot (
	input  logic        clk_cpu,
	input  logic        reset,
	input  logic [18:1] addr,
	input  logic [15:0] din,
	input  logic        we,
	input  logic        rd,
	input  logic         tmek,
	output logic         override,
	output logic [15:0] dout,
	output logic        busy
);

	// word addresses = byte offset (atarixga.cpp PR_*) >> 1
	localparam [18:1] PR_SETKEY   = 18'h22008;
	localparam [18:1] PR_DECIPHER = 18'h22011;
	localparam [18:1] PR_STATUS   = 18'h22380;
	localparam [18:1] PR_DONE0    = 18'h263e0;
	localparam [18:1] PR_RESULT   = 18'h263e1;
	localparam [18:1] PR_DONE4    = 18'h263e2;
	localparam [18:1] PR_DATA     = 18'h23c00;
	localparam [18:1] PR_CHAR0    = 18'h24380;
	localparam [18:1] PR_CHAR1    = 18'h32000;
	localparam [18:1] PR_CHAR2    = 18'h36000;

	// T-MEK word addresses (MAME atarixga.cpp TM_* byte offsets in the D80000
	// window >> 1)
	localparam [18:1] TM_COLOR    = 18'h18000;
	localparam [18:1] TM_DATA     = 18'h1C000;
	localparam [18:1] TM_SETKEY   = 18'h1C008;
	localparam [18:1] TM_DECIPHER = 18'h1C011;
	localparam [18:1] TM_ENDKEY   = 18'h1C244;
	localparam [18:1] TM_STATUS   = 18'h1C380;
	localparam [18:1] TM_RESULT   = 18'h1C3E0;

	localparam RAM_WORDS = 2048;
	localparam [18:1] PR_DATA_END = PR_DATA + 18'd2048;
	localparam [18:1] TM_DATA_END = TM_DATA + 18'd2048;

	localparam [1:0] MODE_IDLE     = 2'd0;
	localparam [1:0] MODE_SETKEY   = 2'd1;
	localparam [1:0] MODE_DECIPHER = 2'd2;

	(* ramstyle = "M10K" *) logic [7:0] ram [0:RAM_WORDS-1];
	logic [1:0] mode;
	logic [15:0] taps;
	logic [15:0] reply;
	logic        select_pending; // T-MEK: RESULT write with 0x0002/0x1234 arms the next STATUS write

	logic in_data_range;
	logic [10:0] data_index;
	assign in_data_range = tmek ? (addr >= TM_DATA) && (addr < TM_DATA_END)
	                             : (addr >= PR_DATA) && (addr < PR_DATA_END);
	// low 11 bits of the word address: the RAM index (works unaligned too,
	// since the window is exactly 2048 words and the subtraction is mod 2^11)
	assign data_index = tmek ? (addr[11:1] - TM_DATA[11:1]) : (addr[11:1] - PR_DATA[11:1]);

	// decipher engine: one LFSR clock per cycle, matches atari_136094_0004a_device::decipher
	localparam [2:0] ENG_IDLE  = 3'd0;
	localparam [2:0] ENG_FETCH = 3'd1;
	localparam [2:0] ENG_KMAP  = 3'd2;
	localparam [2:0] ENG_SETUP = 3'd3;
	localparam [2:0] ENG_LOOP1 = 3'd4;
	localparam [2:0] ENG_CHECK = 3'd5;
	localparam [2:0] ENG_LOOP2 = 3'd6;

	logic [2:0]  eng_state;
	logic [10:0] eng_koff;   // registered key RAM read address, for M10K inference
	logic [7:0]  eng_kbyte;  // registered key RAM read data
	logic [7:0]  eng_n;      // registered kmap ROM read data
	logic [15:0] eng_c;
	logic [15:0] eng_x;
	logic [15:0] eng_x0; // SETUP's substituted start state, for the LOOP2 restart
	logic [7:0]  eng_clocks;
	logic [7:0]  eng_cnt;
	logic        eng_early;

	function automatic [10:0] key_offset(input [10:0] index);
		// bit permutation of the query index, transcribed from atarixga.cpp
		key_offset = { (index[10] ^ 1'b0),
					   (index[9] ^ 1'b0),
					   (index[8] ^ 1'b0),
					   (index[6] ^ 1'b1),
					   (index[7] ^ 1'b0),
					   (index[1] ^ 1'b0),
					   (index[0] ^ 1'b1),
					   (index[4] ^ 1'b0),
					   (index[2] ^ 1'b1),
					   (index[5] ^ 1'b1),
					   (index[3] ^ 1'b0) };
	endfunction

	// kmap[k]: number of LFSR clocks for key byte k, verbatim from atarixga.cpp
	function automatic [7:0] kmap(input [7:0] k);
		case (k)
			8'h00: kmap = 8'h00; 8'h01: kmap = 8'h00; 8'h02: kmap = 8'h00; 8'h03: kmap = 8'h00;
			8'h04: kmap = 8'h00; 8'h05: kmap = 8'h59; 8'h06: kmap = 8'h17; 8'h07: kmap = 8'h7b;
			8'h08: kmap = 8'h00; 8'h09: kmap = 8'h00; 8'h0a: kmap = 8'h4f; 8'h0b: kmap = 8'h27;
			8'h0c: kmap = 8'h00; 8'h0d: kmap = 8'h00; 8'h0e: kmap = 8'h3d; 8'h0f: kmap = 8'h00;
			8'h10: kmap = 8'h00; 8'h11: kmap = 8'h00; 8'h12: kmap = 8'h00; 8'h13: kmap = 8'h00;
			8'h14: kmap = 8'h00; 8'h15: kmap = 8'h67; 8'h16: kmap = 8'h00; 8'h17: kmap = 8'h6f;
			8'h18: kmap = 8'h00; 8'h19: kmap = 8'h65; 8'h1a: kmap = 8'h57; 8'h1b: kmap = 8'h00;
			8'h1c: kmap = 8'h45; 8'h1d: kmap = 8'h4b; 8'h1e: kmap = 8'h00; 8'h1f: kmap = 8'h00;
			8'h20: kmap = 8'h1b; 8'h21: kmap = 8'h1d; 8'h22: kmap = 8'h19; 8'h23: kmap = 8'h00;
			8'h24: kmap = 8'h00; 8'h25: kmap = 8'h61; 8'h26: kmap = 8'h3f; 8'h27: kmap = 8'h00;
			8'h28: kmap = 8'h5f; 8'h29: kmap = 8'h00; 8'h2a: kmap = 8'h00; 8'h2b: kmap = 8'h00;
			8'h2c: kmap = 8'h00; 8'h2d: kmap = 8'h2d; 8'h2e: kmap = 8'h00; 8'h2f: kmap = 8'h00;
			8'h30: kmap = 8'h1f; 8'h31: kmap = 8'h00; 8'h32: kmap = 8'h5b; 8'h33: kmap = 8'h7d;
			8'h34: kmap = 8'h00; 8'h35: kmap = 8'h00; 8'h36: kmap = 8'h00; 8'h37: kmap = 8'h00;
			8'h38: kmap = 8'h00; 8'h39: kmap = 8'h23; 8'h3a: kmap = 8'h00; 8'h3b: kmap = 8'h53;
			8'h3c: kmap = 8'h15; 8'h3d: kmap = 8'h6d; 8'h3e: kmap = 8'h79; 8'h3f: kmap = 8'h00;
			8'h40: kmap = 8'h5d; 8'h41: kmap = 8'h21; 8'h42: kmap = 8'h00; 8'h43: kmap = 8'h00;
			8'h44: kmap = 8'h00; 8'h45: kmap = 8'h00; 8'h46: kmap = 8'h00; 8'h47: kmap = 8'h47;
			8'h48: kmap = 8'h00; 8'h49: kmap = 8'h6b; 8'h4a: kmap = 8'h2b; 8'h4b: kmap = 8'h13;
			8'h4c: kmap = 8'h75; 8'h4d: kmap = 8'h33; 8'h4e: kmap = 8'h00; 8'h4f: kmap = 8'h37;
			8'h50: kmap = 8'h00; 8'h51: kmap = 8'h00; 8'h52: kmap = 8'h69; 8'h53: kmap = 8'h71;
			8'h54: kmap = 8'h25; 8'h55: kmap = 8'h55; 8'h56: kmap = 8'h4d; 8'h57: kmap = 8'h00;
			8'h58: kmap = 8'h73; 8'h59: kmap = 8'h00; 8'h5a: kmap = 8'h31; 8'h5b: kmap = 8'h00;
			8'h5c: kmap = 8'h00; 8'h5d: kmap = 8'h00; 8'h5e: kmap = 8'h3b; 8'h5f: kmap = 8'h00;
			8'h60: kmap = 8'h00; 8'h61: kmap = 8'h00; 8'h62: kmap = 8'h00; 8'h63: kmap = 8'h41;
			8'h64: kmap = 8'h00; 8'h65: kmap = 8'h51; 8'h66: kmap = 8'h00; 8'h67: kmap = 8'h00;
			8'h68: kmap = 8'h00; 8'h69: kmap = 8'h00; 8'h6a: kmap = 8'h00; 8'h6b: kmap = 8'h00;
			8'h6c: kmap = 8'h00; 8'h6d: kmap = 8'h00; 8'h6e: kmap = 8'h00; 8'h6f: kmap = 8'h77;
			8'h70: kmap = 8'h00; 8'h71: kmap = 8'h00; 8'h72: kmap = 8'h00; 8'h73: kmap = 8'h63;
			8'h74: kmap = 8'h29; 8'h75: kmap = 8'h00; 8'h76: kmap = 8'h11; 8'h77: kmap = 8'h2f;
			8'h78: kmap = 8'h00; 8'h79: kmap = 8'h43; 8'h7a: kmap = 8'h00; 8'h7b: kmap = 8'h49;
			8'h7c: kmap = 8'h00; 8'h7d: kmap = 8'h00; 8'h7e: kmap = 8'h35; 8'h7f: kmap = 8'h39;
			8'h80: kmap = 8'h00; 8'h81: kmap = 8'h00; 8'h82: kmap = 8'h00; 8'h83: kmap = 8'h64;
			8'h84: kmap = 8'h00; 8'h85: kmap = 8'h22; 8'h86: kmap = 8'h00; 8'h87: kmap = 8'h42;
			8'h88: kmap = 8'h00; 8'h89: kmap = 8'h6a; 8'h8a: kmap = 8'h20; 8'h8b: kmap = 8'h00;
			8'h8c: kmap = 8'h00; 8'h8d: kmap = 8'h00; 8'h8e: kmap = 8'h1c; 8'h8f: kmap = 8'h00;
			8'h90: kmap = 8'h66; 8'h91: kmap = 8'h00; 8'h92: kmap = 8'h54; 8'h93: kmap = 8'h4a;
			8'h94: kmap = 8'h00; 8'h95: kmap = 8'h6c; 8'h96: kmap = 8'h00; 8'h97: kmap = 8'h00;
			8'h98: kmap = 8'h58; 8'h99: kmap = 8'h32; 8'h9a: kmap = 8'h00; 8'h9b: kmap = 8'h00;
			8'h9c: kmap = 8'h50; 8'h9d: kmap = 8'h2c; 8'h9e: kmap = 8'h60; 8'h9f: kmap = 8'h00;
			8'ha0: kmap = 8'h70; 8'ha1: kmap = 8'h00; 8'ha2: kmap = 8'h00; 8'ha3: kmap = 8'h00;
			8'ha4: kmap = 8'h7c; 8'ha5: kmap = 8'h48; 8'ha6: kmap = 8'h62; 8'ha7: kmap = 8'h52;
			8'ha8: kmap = 8'h00; 8'ha9: kmap = 8'h26; 8'haa: kmap = 8'h00; 8'hab: kmap = 8'h12;
			8'hac: kmap = 8'h00; 8'had: kmap = 8'h00; 8'hae: kmap = 8'h40; 8'haf: kmap = 8'h00;
			8'hb0: kmap = 8'h00; 8'hb1: kmap = 8'h00; 8'hb2: kmap = 8'h6e; 8'hb3: kmap = 8'h00;
			8'hb4: kmap = 8'h00; 8'hb5: kmap = 8'h38; 8'hb6: kmap = 8'h2e; 8'hb7: kmap = 8'h00;
			8'hb8: kmap = 8'h46; 8'hb9: kmap = 8'h00; 8'hba: kmap = 8'h7a; 8'hbb: kmap = 8'h36;
			8'hbc: kmap = 8'h00; 8'hbd: kmap = 8'h76; 8'hbe: kmap = 8'h00; 8'hbf: kmap = 8'h00;
			8'hc0: kmap = 8'h00; 8'hc1: kmap = 8'h72; 8'hc2: kmap = 8'h00; 8'hc3: kmap = 8'h00;
			8'hc4: kmap = 8'h00; 8'hc5: kmap = 8'h00; 8'hc6: kmap = 8'h1e; 8'hc7: kmap = 8'h00;
			8'hc8: kmap = 8'h00; 8'hc9: kmap = 8'h00; 8'hca: kmap = 8'h5c; 8'hcb: kmap = 8'h00;
			8'hcc: kmap = 8'h00; 8'hcd: kmap = 8'h5e; 8'hce: kmap = 8'h1a; 8'hcf: kmap = 8'h00;
			8'hd0: kmap = 8'h00; 8'hd1: kmap = 8'h00; 8'hd2: kmap = 8'h24; 8'hd3: kmap = 8'h44;
			8'hd4: kmap = 8'h28; 8'hd5: kmap = 8'h14; 8'hd6: kmap = 8'h00; 8'hd7: kmap = 8'h00;
			8'hd8: kmap = 8'h00; 8'hd9: kmap = 8'h74; 8'hda: kmap = 8'h00; 8'hdb: kmap = 8'h00;
			8'hdc: kmap = 8'h00; 8'hdd: kmap = 8'h00; 8'hde: kmap = 8'h00; 8'hdf: kmap = 8'h00;
			8'he0: kmap = 8'h68; 8'he1: kmap = 8'h56; 8'he2: kmap = 8'h00; 8'he3: kmap = 8'h30;
			8'he4: kmap = 8'h5a; 8'he5: kmap = 8'h00; 8'he6: kmap = 8'h00; 8'he7: kmap = 8'h00;
			8'he8: kmap = 8'h00; 8'he9: kmap = 8'h4e; 8'hea: kmap = 8'h00; 8'heb: kmap = 8'h2a;
			8'hec: kmap = 8'h18; 8'hed: kmap = 8'h00; 8'hee: kmap = 8'h00; 8'hef: kmap = 8'h00;
			8'hf0: kmap = 8'h4c; 8'hf1: kmap = 8'h00; 8'hf2: kmap = 8'h00; 8'hf3: kmap = 8'h3a;
			8'hf4: kmap = 8'h00; 8'hf5: kmap = 8'h34; 8'hf6: kmap = 8'h10; 8'hf7: kmap = 8'h78;
			8'hf8: kmap = 8'h00; 8'hf9: kmap = 8'h3c; 8'hfa: kmap = 8'h16; 8'hfb: kmap = 8'h00;
			8'hfc: kmap = 8'h3e; 8'hfd: kmap = 8'h00; 8'hfe: kmap = 8'h00; 8'hff: kmap = 8'h00;
			default: kmap = 8'h00;
		endcase
	endfunction

	function automatic [10:0] key_offset_tm(input [10:0] index);
		// spclords_key_offset(index): bitswap<12>(index*2, 12,11,10,9,6,3,5,4,1,7,2,8) ^ 0x0b3;
		// index*2 has bit0 = 0 and bit12 = 0 (index fits in 11 bits), so the
		// permutation reduces to these 11 index bits, XORed with 0x0b3
		key_offset_tm = { index[10], index[9], index[8], ~index[5], index[2],
		                  ~index[4], ~index[3], index[0], index[6], ~index[1], ~index[7] };
	endfunction

	// T-MEK clocks: xga_clock_count(k) directly on the raw key byte (no
	// preceding bitswap<8>, unlike PR's kmap), same SPCLORDS_CLOCKS(0x53) table
	function automatic [7:0] kmap_tm(input [7:0] k);
		case (k)
			8'h00: kmap_tm = 8'h0e; 8'h01: kmap_tm = 8'h4a; 8'h02: kmap_tm = 8'h1b; 8'h03: kmap_tm = 8'h19;
			8'h04: kmap_tm = 8'h6c; 8'h05: kmap_tm = 8'h17; 8'h06: kmap_tm = 8'h38; 8'h07: kmap_tm = 8'h3f;
			8'h08: kmap_tm = 8'h0e; 8'h09: kmap_tm = 8'h64; 8'h0a: kmap_tm = 8'h1f; 8'h0b: kmap_tm = 8'h5b;
			8'h0c: kmap_tm = 8'h22; 8'h0d: kmap_tm = 8'h42; 8'h0e: kmap_tm = 8'h48; 8'h0f: kmap_tm = 8'h52;
			8'h10: kmap_tm = 8'h32; 8'h11: kmap_tm = 8'h4f; 8'h12: kmap_tm = 8'h5f; 8'h13: kmap_tm = 8'h36;
			8'h14: kmap_tm = 8'h2c; 8'h15: kmap_tm = 8'h3d; 8'h16: kmap_tm = 8'h76; 8'h17: kmap_tm = 8'h0e;
			8'h18: kmap_tm = 8'h6a; 8'h19: kmap_tm = 8'h57; 8'h1a: kmap_tm = 8'h26; 8'h1b: kmap_tm = 8'h12;
			8'h1c: kmap_tm = 8'h45; 8'h1d: kmap_tm = 8'h0e; 8'h1e: kmap_tm = 8'h15; 8'h1f: kmap_tm = 8'h79;
			8'h20: kmap_tm = 8'h66; 8'h21: kmap_tm = 8'h54; 8'h22: kmap_tm = 8'h1d; 8'h23: kmap_tm = 8'h6e;
			8'h24: kmap_tm = 8'h59; 8'h25: kmap_tm = 8'h7b; 8'h26: kmap_tm = 8'h61; 8'h27: kmap_tm = 8'h2e;
			8'h28: kmap_tm = 8'h0e; 8'h29: kmap_tm = 8'h7e; 8'h2a: kmap_tm = 8'h70; 8'h2b: kmap_tm = 8'h7d;
			8'h2c: kmap_tm = 8'h67; 8'h2d: kmap_tm = 8'h6f; 8'h2e: kmap_tm = 8'h7c; 8'h2f: kmap_tm = 8'h62;
			8'h30: kmap_tm = 8'h58; 8'h31: kmap_tm = 8'h27; 8'h32: kmap_tm = 8'h46; 8'h33: kmap_tm = 8'h7a;
			8'h34: kmap_tm = 8'h50; 8'h35: kmap_tm = 8'h60; 8'h36: kmap_tm = 8'h2d; 8'h37: kmap_tm = 8'h0f;
			8'h38: kmap_tm = 8'h65; 8'h39: kmap_tm = 8'h20; 8'h3a: kmap_tm = 8'h23; 8'h3b: kmap_tm = 8'h53;
			8'h3c: kmap_tm = 8'h4b; 8'h3d: kmap_tm = 8'h1c; 8'h3e: kmap_tm = 8'h6d; 8'h3f: kmap_tm = 8'h40;
			8'h40: kmap_tm = 8'h5d; 8'h41: kmap_tm = 8'h44; 8'h42: kmap_tm = 8'h0e; 8'h43: kmap_tm = 8'h3a;
			8'h44: kmap_tm = 8'h14; 8'h45: kmap_tm = 8'h0e; 8'h46: kmap_tm = 8'h34; 8'h47: kmap_tm = 8'h78;
			8'h48: kmap_tm = 8'h72; 8'h49: kmap_tm = 8'h69; 8'h4a: kmap_tm = 8'h56; 8'h4b: kmap_tm = 8'h30;
			8'h4c: kmap_tm = 8'h25; 8'h4d: kmap_tm = 8'h4d; 8'h4e: kmap_tm = 8'h29; 8'h4f: kmap_tm = 8'h11;
			8'h50: kmap_tm = 8'h74; 8'h51: kmap_tm = 8'h2b; 8'h52: kmap_tm = 8'h3c; 8'h53: kmap_tm = 8'h0e;
			8'h54: kmap_tm = 8'h75; 8'h55: kmap_tm = 8'h0e; 8'h56: kmap_tm = 8'h0e; 8'h57: kmap_tm = 8'h0e;
			8'h58: kmap_tm = 8'h73; 8'h59: kmap_tm = 8'h31; 8'h5a: kmap_tm = 8'h4e; 8'h5b: kmap_tm = 8'h2a;
			8'h5c: kmap_tm = 8'h5e; 8'h5d: kmap_tm = 8'h3b; 8'h5e: kmap_tm = 8'h0e; 8'h5f: kmap_tm = 8'h35;
			8'h60: kmap_tm = 8'h21; 8'h61: kmap_tm = 8'h24; 8'h62: kmap_tm = 8'h4c; 8'h63: kmap_tm = 8'h41;
			8'h64: kmap_tm = 8'h28; 8'h65: kmap_tm = 8'h47; 8'h66: kmap_tm = 8'h51; 8'h67: kmap_tm = 8'h10;
			8'h68: kmap_tm = 8'h0e; 8'h69: kmap_tm = 8'h71; 8'h6a: kmap_tm = 8'h68; 8'h6b: kmap_tm = 8'h63;
			8'h6c: kmap_tm = 8'h55; 8'h6d: kmap_tm = 8'h1e; 8'h6e: kmap_tm = 8'h5a; 8'h6f: kmap_tm = 8'h2f;
			8'h70: kmap_tm = 8'h6b; 8'h71: kmap_tm = 8'h13; 8'h72: kmap_tm = 8'h0e; 8'h73: kmap_tm = 8'h16;
			8'h74: kmap_tm = 8'h33; 8'h75: kmap_tm = 8'h37; 8'h76: kmap_tm = 8'h3e; 8'h77: kmap_tm = 8'h77;
			8'h78: kmap_tm = 8'h0e; 8'h79: kmap_tm = 8'h5c; 8'h7a: kmap_tm = 8'h43; 8'h7b: kmap_tm = 8'h49;
			8'h7c: kmap_tm = 8'h0e; 8'h7d: kmap_tm = 8'h1a; 8'h7e: kmap_tm = 8'h18; 8'h7f: kmap_tm = 8'h39;
			8'h80: kmap_tm = 8'h0e; 8'h81: kmap_tm = 8'h7e; 8'h82: kmap_tm = 8'h70; 8'h83: kmap_tm = 8'h7d;
			8'h84: kmap_tm = 8'h67; 8'h85: kmap_tm = 8'h6f; 8'h86: kmap_tm = 8'h7c; 8'h87: kmap_tm = 8'h62;
			8'h88: kmap_tm = 8'h66; 8'h89: kmap_tm = 8'h54; 8'h8a: kmap_tm = 8'h1d; 8'h8b: kmap_tm = 8'h6e;
			8'h8c: kmap_tm = 8'h59; 8'h8d: kmap_tm = 8'h7b; 8'h8e: kmap_tm = 8'h61; 8'h8f: kmap_tm = 8'h2e;
			8'h90: kmap_tm = 8'h65; 8'h91: kmap_tm = 8'h20; 8'h92: kmap_tm = 8'h23; 8'h93: kmap_tm = 8'h53;
			8'h94: kmap_tm = 8'h4b; 8'h95: kmap_tm = 8'h1c; 8'h96: kmap_tm = 8'h6d; 8'h97: kmap_tm = 8'h40;
			8'h98: kmap_tm = 8'h58; 8'h99: kmap_tm = 8'h27; 8'h9a: kmap_tm = 8'h46; 8'h9b: kmap_tm = 8'h7a;
			8'h9c: kmap_tm = 8'h50; 8'h9d: kmap_tm = 8'h60; 8'h9e: kmap_tm = 8'h2d; 8'h9f: kmap_tm = 8'h0f;
			8'ha0: kmap_tm = 8'h0e; 8'ha1: kmap_tm = 8'h64; 8'ha2: kmap_tm = 8'h1f; 8'ha3: kmap_tm = 8'h5b;
			8'ha4: kmap_tm = 8'h22; 8'ha5: kmap_tm = 8'h42; 8'ha6: kmap_tm = 8'h48; 8'ha7: kmap_tm = 8'h52;
			8'ha8: kmap_tm = 8'h0e; 8'ha9: kmap_tm = 8'h4a; 8'haa: kmap_tm = 8'h1b; 8'hab: kmap_tm = 8'h19;
			8'hac: kmap_tm = 8'h6c; 8'had: kmap_tm = 8'h17; 8'hae: kmap_tm = 8'h38; 8'haf: kmap_tm = 8'h3f;
			8'hb0: kmap_tm = 8'h6a; 8'hb1: kmap_tm = 8'h57; 8'hb2: kmap_tm = 8'h26; 8'hb3: kmap_tm = 8'h12;
			8'hb4: kmap_tm = 8'h45; 8'hb5: kmap_tm = 8'h0e; 8'hb6: kmap_tm = 8'h15; 8'hb7: kmap_tm = 8'h79;
			8'hb8: kmap_tm = 8'h32; 8'hb9: kmap_tm = 8'h4f; 8'hba: kmap_tm = 8'h5f; 8'hbb: kmap_tm = 8'h36;
			8'hbc: kmap_tm = 8'h2c; 8'hbd: kmap_tm = 8'h3d; 8'hbe: kmap_tm = 8'h76; 8'hbf: kmap_tm = 8'h0e;
			8'hc0: kmap_tm = 8'h0e; 8'hc1: kmap_tm = 8'h71; 8'hc2: kmap_tm = 8'h68; 8'hc3: kmap_tm = 8'h63;
			8'hc4: kmap_tm = 8'h55; 8'hc5: kmap_tm = 8'h1e; 8'hc6: kmap_tm = 8'h5a; 8'hc7: kmap_tm = 8'h2f;
			8'hc8: kmap_tm = 8'h21; 8'hc9: kmap_tm = 8'h24; 8'hca: kmap_tm = 8'h4c; 8'hcb: kmap_tm = 8'h41;
			8'hcc: kmap_tm = 8'h28; 8'hcd: kmap_tm = 8'h47; 8'hce: kmap_tm = 8'h51; 8'hcf: kmap_tm = 8'h10;
			8'hd0: kmap_tm = 8'h0e; 8'hd1: kmap_tm = 8'h5c; 8'hd2: kmap_tm = 8'h43; 8'hd3: kmap_tm = 8'h49;
			8'hd4: kmap_tm = 8'h0e; 8'hd5: kmap_tm = 8'h1a; 8'hd6: kmap_tm = 8'h18; 8'hd7: kmap_tm = 8'h39;
			8'hd8: kmap_tm = 8'h6b; 8'hd9: kmap_tm = 8'h13; 8'hda: kmap_tm = 8'h0e; 8'hdb: kmap_tm = 8'h16;
			8'hdc: kmap_tm = 8'h33; 8'hdd: kmap_tm = 8'h37; 8'hde: kmap_tm = 8'h3e; 8'hdf: kmap_tm = 8'h77;
			8'he0: kmap_tm = 8'h72; 8'he1: kmap_tm = 8'h69; 8'he2: kmap_tm = 8'h56; 8'he3: kmap_tm = 8'h30;
			8'he4: kmap_tm = 8'h25; 8'he5: kmap_tm = 8'h4d; 8'he6: kmap_tm = 8'h29; 8'he7: kmap_tm = 8'h11;
			8'he8: kmap_tm = 8'h5d; 8'he9: kmap_tm = 8'h44; 8'hea: kmap_tm = 8'h0e; 8'heb: kmap_tm = 8'h3a;
			8'hec: kmap_tm = 8'h14; 8'hed: kmap_tm = 8'h0e; 8'hee: kmap_tm = 8'h34; 8'hef: kmap_tm = 8'h78;
			8'hf0: kmap_tm = 8'h73; 8'hf1: kmap_tm = 8'h31; 8'hf2: kmap_tm = 8'h4e; 8'hf3: kmap_tm = 8'h2a;
			8'hf4: kmap_tm = 8'h5e; 8'hf5: kmap_tm = 8'h3b; 8'hf6: kmap_tm = 8'h0e; 8'hf7: kmap_tm = 8'h35;
			8'hf8: kmap_tm = 8'h74; 8'hf9: kmap_tm = 8'h2b; 8'hfa: kmap_tm = 8'h3c; 8'hfb: kmap_tm = 8'h0e;
			8'hfc: kmap_tm = 8'h75; 8'hfd: kmap_tm = 8'h0e; 8'hfe: kmap_tm = 8'h0e; 8'hff: kmap_tm = 8'h0e;
		endcase
	endfunction

	function automatic [15:0] lfsr_step(input [15:0] x, input [15:0] t);
		lfsr_step = { x[14:0], ^(x & t) };
	endfunction

	logic [15:0] eng_x_next;
	assign eng_x_next = lfsr_step(eng_x, taps);

	// a write in DECIPHER mode (re)arms the engine and aborts any run still in
	// progress (MAME: last write wins); busy stays high up to about 6 us at clk_cpu = 42.955 MHz
	logic restart;
	assign restart = we && in_data_range && (mode == MODE_DECIPHER);

	always_ff @(posedge clk_cpu) begin
		if (reset) begin
			mode      <= MODE_IDLE;
			taps      <= tmek ? 16'hc100 : 16'h0000;
			reply     <= tmek ? 16'hffff : 16'h0000;
			select_pending <= 1'b0;
			override  <= 1'b0;
			dout      <= 16'h0000;
			eng_state <= ENG_IDLE;
			busy      <= 1'b0;
		end else begin
			override <= 1'b0;

			if (we) begin
				if (in_data_range && mode == MODE_SETKEY) begin
					ram[data_index] <= din[7:0];
				end else if (!restart) begin
					if (tmek) begin
						if (addr == TM_COLOR) begin
							// normal palette write ends key upload/query mode;
							// the actual pass-through to colour RAM is cpu_bus's job
							mode <= MODE_IDLE;
						end else if (addr == TM_RESULT) begin
							if (din == 16'h0002 || din == 16'h1234)
								select_pending <= 1'b1;
						end else if (addr == TM_STATUS && select_pending) begin
							taps <= 16'hc100 | {8'h00, din[7:0]};
							select_pending <= 1'b0;
						end
					end else begin
						if (addr == PR_CHAR0 || addr == PR_CHAR1 || addr == PR_CHAR2) begin
							case (din)
								16'h2694: taps <= 16'hbcc8; // Sauron, Diablo
								16'h6ee0: taps <= 16'haed5; // Blizzard, Talon
								16'h34f7: taps <= 16'h9d79; // Chaos
								16'h32b9: taps <= 16'hfd10; // Vertigo
								16'h4d5a: taps <= 16'h82a3; // Armadon
								default: ; // unknown word: taps unchanged
							endcase
						end
					end
				end
			end

			if (rd) begin
				if (tmek) begin
					if (addr == TM_SETKEY) begin
						mode <= MODE_SETKEY;
					end else if (addr == TM_DECIPHER) begin
						mode <= MODE_DECIPHER;
					end else if (addr == TM_ENDKEY) begin
						mode <= MODE_IDLE;
					end else if (addr == TM_STATUS) begin
						override <= 1'b1;
						dout     <= 16'h8000;
					end else if (addr == TM_RESULT) begin
						override <= 1'b1;
						dout     <= reply; // cpu_bus stalls on busy, so this is always the fresh reply
						mode     <= MODE_IDLE;
					end
				end else begin
					if (addr == PR_SETKEY) begin
						mode <= MODE_SETKEY;
					end else if (addr == PR_DECIPHER) begin
						mode <= MODE_DECIPHER;
					end else if (addr == PR_DONE0 || addr == PR_DONE4) begin
						if (mode == MODE_SETKEY)
							mode <= MODE_IDLE;
					end else if (addr == PR_STATUS) begin
						override <= 1'b1;
						dout     <= 16'h8000;
					end else if (addr == PR_RESULT) begin
						if (mode == MODE_DECIPHER) begin
							override <= 1'b1;
							dout     <= reply; // cpu_bus stalls on busy, so this is always the fresh reply
							mode     <= MODE_IDLE;
						end
					end
				end
			end

			// decipher engine, one LFSR clock per cycle; restart always wins over
			// whatever step the engine was mid-way through
			if (restart) begin
				eng_c     <= din;
				eng_koff  <= tmek ? key_offset_tm(data_index) : key_offset(data_index);
				eng_state <= ENG_FETCH;
				busy      <= 1'b1;
				// T-MEK: write16 returns to IDLE right on the triggering write
				// (MAME atarixga.cpp:526-530), not deferred to the RESULT read;
				// a later write here would otherwise be misread as a second query
				if (tmek) mode <= MODE_IDLE;
			end else begin
				case (eng_state)
					ENG_IDLE: ; // waits for a write in DECIPHER mode to arm it

					ENG_FETCH: begin
						eng_kbyte <= ram[eng_koff]; // synchronous read, registered address
						eng_state <= ENG_KMAP;
					end

					ENG_KMAP: begin
						eng_n     <= tmek ? kmap_tm(eng_kbyte) : kmap(eng_kbyte); // synchronous ROM read, registered address
						eng_state <= ENG_SETUP;
					end

					ENG_SETUP: begin
						eng_x      <= (eng_c == 16'h0000) ? 16'h0001 : eng_c;
						eng_x0     <= (eng_c == 16'h0000) ? 16'h0001 : eng_c;
						eng_clocks <= (eng_c == 16'h0000)
										? (eng_n == 8'h00 ? 8'h00 : eng_n - 8'h01)
										: eng_n;
						eng_cnt    <= 8'h00;
						eng_early  <= 1'b0;
						eng_state  <= ENG_LOOP1;
					end

					ENG_LOOP1: begin
						if (eng_cnt == eng_clocks) begin
							eng_state <= ENG_CHECK;
						end else begin
							eng_x   <= eng_x_next;
							if (eng_x_next == 16'h0001)
								eng_early <= 1'b1;
							eng_cnt <= eng_cnt + 8'h01;
						end
					end

					ENG_CHECK: begin
						if (eng_early) begin
							if (eng_x == 16'h0001) begin
								reply     <= 16'h0000;
								eng_state <= ENG_IDLE;
								busy      <= 1'b0;
							end else begin
								// restart from the SETUP start state (eng_x0), not the
								// raw ciphertext: when c==0 that start state is 1, and
								// eng_c==0 is a fixed point of the LFSR (MAME atarixga.cpp:100)
								eng_x     <= eng_x0;
								eng_cnt   <= 8'h00;
								eng_state <= ENG_LOOP2;
							end
						end else begin
							reply     <= eng_x;
							eng_state <= ENG_IDLE;
							busy      <= 1'b0;
						end
					end

					ENG_LOOP2: begin
						if (eng_cnt == eng_clocks - 8'h01) begin
							reply     <= eng_x;
							eng_state <= ENG_IDLE;
							busy      <= 1'b0;
						end else begin
							eng_x   <= eng_x_next;
							eng_cnt <= eng_cnt + 8'h01;
						end
					end

					default: eng_state <= ENG_IDLE;
				endcase
			end
		end
	end

endmodule
