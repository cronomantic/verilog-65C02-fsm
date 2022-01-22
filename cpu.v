/*
 * verilog model of 65C02 CPU.
 *
 * (C) Arlet Ottens, <arlet@c-scape.nl>
 *
 */

module cpu( 
    input clk,                          // CPU clock
    input RST,                          // RST signal
    output reg [15:0] AD,               // address bus (combinatorial) 
    output sync,                        // start of new instruction
    input [7:0] DI,                     // data bus input
    output reg [7:0] DO,                // data bus output 
    output reg WE,                      // write enable
    input IRQ,                          // interrupt request
    input NMI,                          // non-maskable interrupt request
    input RDY,                          // Ready signal. Pauses CPU when RDY=0
    input debug );                      // debug for simulation

reg [15:0] PC = 16'hf800;               // program counter high
wire [7:0] ADH = AD[15:8];
wire [7:0] ADL = AD[7:0];
wire [7:0] PCH = PC[15:8];
wire [7:0] PCL = PC[7:0];

reg [7:0] AHL;
reg [15:0] AB;                          // registered address
wire [7:0] IR;                          // instruction register

wire B = 1;
reg N, V, D, I, Z, C;                   // processor status flags 
wire [7:0] P = { N, V, 1'b1, B, D, I, Z, C };

/*
 * state
 */

parameter
    SYNC  = 5'd0,
    IMMI  = 5'd1,
    PHA0  = 5'd2,
    PLA0  = 5'd3,
    ZERO  = 5'd4,
    DATA  = 5'd5,
    ABS0  = 5'd6,
    ABS1  = 5'd7,
    BRA0  = 5'd8,
    JSR0  = 5'd9,
    JSR1  = 5'd10,
    JSR2  = 5'd11,
    JSR3  = 5'd12,
    RTS0  = 5'd13,
    RTS1  = 5'd14,
    RTS2  = 5'd15,
    JMP0  = 5'd16,
    JMP1  = 5'd17,
    IDX0  = 5'd18,
    IDX1  = 5'd19,
    IDX2  = 5'd20,
    RDWR  = 5'd21,
    BRK0  = 5'd22,
    BRK1  = 5'd23,
    BRK2  = 5'd24,
    BRK3  = 5'd25,
    RTI0  = 5'd26,
    IND0  = 5'd27,
    IND1  = 5'd28,
    RST0  = 5'd29,
    XXXX  = 5'dx;

/*
 * control bits
 */

reg [5:0] state;
assign sync = (state == SYNC);
reg [25:0] control;
wire rot = control[25];
wire adc_sbc = control[24];
wire shift = control[23];
wire cmp = control[22];
wire cli_sei = control[21];
wire cld_sed = control[20];
wire clc_sec = control[19];
wire bit_isn = control[18];
wire clv = control[17];
wire php = control[16];
wire plp = control[15];
wire rti = control[14];
wire txs = control[13];
wire rmw = control[12];
wire sta = control[11];
wire ld = control[10];
wire [1:0] ctl_src = control[9:8];
wire [1:0] ctl_dst = control[7:6];
wire [3:0] alu_op = control[5:2];
reg set;
reg [3:0] cond_code;
reg cond;

/*
 * register file
 */
reg [7:0] regs[31:0];                   // register file

reg [5:0] reg_op;
reg [1:0] reg_idx;
wire [7:0] R = regs[ctl_src];
wire [7:0] XY = regs[reg_idx];

parameter
    SEL_Z = 2'b00,
    SEL_X = 2'b01,
    SEL_Y = 2'b10,
    SEL_A = 2'b11;

initial begin
    regs[SEL_Z] = 0;                    // Z register 
    regs[SEL_X] = 1;                    // X register 
    regs[SEL_Y] = 2;                    // Y register
    regs[SEL_A] = 8'h41;                // A register
end

/*
 * pick index register
 */
always @*
    case( state )
        IDX0: reg_idx = {1'b0, control[0]}; // idx = X or Z
        IDX2: reg_idx = {control[1], 1'b0}; // idx = Y or Z
     default: reg_idx = control[1:0];
    endcase

/*
 * write register file. 
 */
always @(posedge clk)
    if( ld & sync )
        regs[ctl_dst] <= alu_out;

/*
 * ALU
 */

reg [7:0] alu_out;
reg [7:0] M;
wire [7:0] NM = M ^ 8'hff;
wire alu_Z = !alu_out;
wire alu_N = alu_out[7];
reg alu_C;
reg alu_V;

parameter
    MOV = 4'b0000,
    INC = 4'b0001,
    DEC = 4'b0010,
    MEM = 4'b0011,
    TSX = 4'b0100,
    PLA = 4'b0101,
    ORA = 4'b0110,
    AND = 4'b0111,
    EOR = 4'b1000,
    ADC = 4'b1001,
    SBC = 4'b1010,
    ASL = 4'b1011,
    LSR = 4'b1100,
    CMP = 4'b1101;

always @* begin
    alu_V = 0;
    case( alu_op )
        ADC: alu_V = R[7] ^  M[7] ^ alu_C ^ alu_out[7]; 
        SBC: alu_V = R[7] ^ NM[7] ^ alu_C ^ alu_out[7]; 
    endcase
end

always @* begin
    alu_out = 8'hAA;
    case( state )
        PHA0: alu_out = R;
        ZERO: alu_out = R;
        ABS1: alu_out = R;
        IDX2: alu_out = R;
        SYNC: case( alu_op )
                  PLA: alu_out = DB;        // if necessary, add delay cycle and use 'M' instead
                  TSX: alu_out = S;
                  MOV: alu_out = R;
                  INC: alu_out = R + 1;
                  DEC: alu_out = R - 1;
                  MEM: alu_out = M;
                  ORA: alu_out = R | M;
                  AND: alu_out = R & M;
                  EOR: alu_out = R ^ M;
                  ADC: {alu_C, alu_out} = R +  M + C;
                  SBC: {alu_C, alu_out} = R + NM + C;
                  CMP: {alu_C, alu_out} = R + NM + 1;
                  ASL: {alu_C, alu_out} = {R, rot & C};
                  LSR: {alu_out, alu_C} = {rot & C, R};
              endcase
        RDWR: case( alu_op )
                  INC: alu_out = M + 1;
                  DEC: alu_out = M - 1;
                  ASL: {alu_C, alu_out} = {M, rot & C};
                  LSR: {alu_out, alu_C} = {rot & C, M};
              endcase
    endcase
end

always @(posedge clk)
    case( state )
        IMMI: M <= DB;
        PLA0: M <= DB;
        DATA: M <= DB;
    endcase

/*
 * databus
 */
wire [7:0] DB = DI;                     // data bus (alias for DB)

/*
 * stack pointer gets its own register
 */

reg [7:0] S = 8'hff;                   // stack pointer

always @(posedge clk)
    case( state )
        SYNC:   if( txs ) S <= X;
        BRK0:   S <= S - 1;
        BRK1:   S <= S - 1;
        BRK2:   S <= S - 1;
        JSR0:   S <= S - 1;
        JSR1:   S <= S - 1;
        PHA0:   S <= S - 1;
        PLA0:   S <= S + 1;
        RTI0:   S <= S + 1;
        RTS0:   S <= S + 1;
        RTS1:   S <= S + 1;
    endcase

/* 
 * address bus
 */

always @*
    case( state )
           BRK0: AD = {8'h01, S};
           BRK1: AD = {8'h01, S};
           BRK2: AD = {8'h01, S};
           BRK3: AD = 16'hfffe;
           JSR0: AD = {8'h01, S};
           JSR1: AD = {8'h01, S};
           JSR2: AD = PC;
           JSR3: AD = {DB, AHL};
           ZERO: AD = {8'h00, DB + XY};
           IDX0: AD = {8'h00, DB + XY};             // XY = X or Z
           IDX1: AD = AB + 1;                       // XY = X or Z
           IDX2: AD = {DB, AHL} + XY;               // XY = Y or Z
           DATA: AD = PC;
           ABS0: AD = PC;
           ABS1: AD = {DB, AHL} + XY;
           JMP0: AD = PC;
           JMP1: AD = {DB, AHL};
           IMMI: AD = PC;
           SYNC: AD = PC; 
           RDWR: AD = AB;
           PHA0: AD = {8'h01, S};
           PLA0: AD = {8'h01, S + 8'h01};
           RTI0: AD = {8'h01, S + 8'h01};
           RTS0: AD = {8'h01, S + 8'h01};
           RTS1: AD = {8'h01, S + 8'h01};
           RTS2: AD = {DB, AHL} + !rti;
           BRA0: if( !cond )      AD = PC;
                 else if( DB[7] ) AD = PC + {8'hff, DB};
                 else             AD = PC + {8'h00, DB};
           IND0: AD = PC;
           IND1: AD = {DB, AHL};
           RST0: AD = PC;
        default: AD = 16'habcd;
    endcase

always @(posedge clk)
    case( state )
        ABS0: AHL <= DB;
        IDX0: AHL <= DB;
        IDX1: AHL <= DB;
        JMP0: AHL <= DB;
        IND0: AHL <= DB;
        JSR0: AHL <= DB;
        RTS1: AHL <= DB;
    endcase

/* 
 * make copy of current address for read-modify-write
 */
always @(posedge clk)
    if( state != DATA )
        AB <= AD;

always @(posedge clk)
    if( RST )
        PC <= 16'hfffc;
    else case( state )
        RST0: PC <= AD + 1;
        SYNC: PC <= AD + 1;
        DATA: PC <= AD + 1;
        IMMI: PC <= AD + 1;
        ABS0: PC <= AD + 1;
        BRA0: PC <= AD + 1;
        JSR3: PC <= AD + 1;
        RTS2: PC <= AD + 1;
        JMP1: PC <= AD + 1;
        IND1: PC <= AD + 1;
        BRK3: PC <= AD + 1;
    endcase

/*
 * write enable
 */

always @*
    case( state )
       ZERO: WE = sta;
       ABS1: WE = sta;
       IDX2: WE = sta;
       RDWR: WE = 1;
       JSR0: WE = 1;
       JSR1: WE = 1;
       BRK0: WE = 1;
       BRK1: WE = 1;
       BRK2: WE = 1;
       PHA0: WE = 1;
    default: WE = 0;
    endcase

/*
 * data output
 */
always @*
    case( state )
       PHA0: DO = php ? P : alu_out;
       ZERO: DO = alu_out;
       ABS1: DO = alu_out;
       RDWR: DO = alu_out;
       IDX2: DO = alu_out;
       JSR0: DO = PCH;
       JSR1: DO = PCL;
       BRK0: DO = PCH;
       BRK1: DO = PCL;
       BRK2: DO = P;
    default: DO = 8'h55;
    endcase

/*
 * flags update
 * NV_BDIZC
 */

/*
 * negative flag
 */
always @(posedge clk)
    case( state )
        RTS0: if( rti )                 N <= DB[7];
        SYNC: if( plp )                 N <= DB[7];
              else if( bit_isn )        N <= M[7];
              else if( ld )             N <= alu_N;
              else if( cmp )            N <= alu_N;
              else if( bit_isn )        N <= alu_N;
        RDWR:                           N <= alu_N;
    endcase


/*
 * overflow flag
 */
always @(posedge clk)
    case( state )
        RTS0: if( rti )                 V <= DB[6];
        SYNC: if( plp )                 V <= DB[6];
              else if( clv )            V <= 0;
              else if( bit_isn )        V <= M[6];
              else if( adc_sbc )        V <= alu_V;
    endcase

/*
 * decimal flag
 */
always @(posedge clk)
    case( state )
        RTS0: if( rti )                 D <= DB[3];
        SYNC: if( plp )                 D <= DB[3];
              else if( cld_sed )        D <= set;
    endcase

/*
 * interrupt flag 
 */
always @(posedge clk)
    case( state )
        BRK3:                           I <= 1;
        RTS0: if( rti )                 I <= DB[2];
        SYNC: if( plp )                 I <= DB[2]; 
              else if( cli_sei )        I <= set;
    endcase

/*
 * zero flag 
 */
always @(posedge clk)
    case( state )
        RTS0: if( rti )                 Z <= DB[1];
        SYNC: if( plp )                 Z <= DB[1]; 
              else if( ld )             Z <= alu_Z;
              else if( cmp )            Z <= alu_Z;
              else if( bit_isn )        Z <= alu_Z;
        RDWR:                           Z <= alu_Z;
    endcase

/*
 * carry flag
 */
always @(posedge clk)
    case( state )
        RTS0: if( rti )                 C <= DB[0];
        SYNC: if( plp )                 C <= DB[0];
              else if( clc_sec )        C <= set;
              else if( cmp )            C <= alu_C;
              else if( shift & ~rmw )   C <= alu_C;
              else if( adc_sbc )        C <= alu_C;
        RDWR: if( shift )               C <= alu_C;
    endcase

/*
 * state machine
 */

reg [8:0] DBHOLD = {9'h1ea};

always @(posedge clk)
    case( state )
        PLA0: DBHOLD <= {1'b1, DB};
        PHA0: DBHOLD <= {1'b1, DB};
        RDWR: DBHOLD <= {1'b1, DB};
    default:  DBHOLD <= {1'b0, DB};
    endcase

assign IR = DBHOLD[8] ? DBHOLD[7:0] : DB;

/*
 * flag set bit to distinguish CLC/SEC and friends
 */
always @(posedge clk) 
    set <= IR[5];

/*
 * condition code
 */
always @(posedge clk) 
    cond_code <= IR[7:4];

always @*
    case( cond_code )
        4'b0001: cond = ~N;
        4'b0011: cond =  N;
        4'b0101: cond = ~V;
        4'b0111: cond =  V;
        4'b1000: cond =  1;
        4'b1001: cond = ~C;
        4'b1011: cond =  C;
        4'b1101: cond = ~Z;
        4'b1111: cond =  Z;
    endcase

always @(posedge clk)
    if( RST )
        state <= RST0;
    else case( state )
        SYNC: case( IR )
                  8'h00: state <= BRK0; // BRK
                  8'h01: state <= IDX0; // ORA (ZP,X)
                  8'h04: state <= ZERO; // TSB ZP
                  8'h05: state <= ZERO; // ORA ZP
                  8'h06: state <= ZERO; // ASL ZP
                  8'h08: state <= PHA0; // PHP
                  8'h09: state <= IMMI; // ORA #IMM
                  8'h0A: state <= SYNC; // ASL A
                  8'h0C: state <= ABS0; // TSB ABS
                  8'h0D: state <= ABS0; // ORA ABS
                  8'h0E: state <= ABS0; // ASL ABS
                  8'h10: state <= BRA0; // BPL
                  8'h11: state <= IDX0; // ORA (ZP),Y
                  8'h12: state <= IDX0; // ORA (ZP)
                  8'h14: state <= ZERO; // TRB ZP
                  8'h15: state <= ZERO; // ORA ZP,X
                  8'h16: state <= ZERO; // ASL ZP,X
                  8'h18: state <= SYNC; // CLC
                  8'h19: state <= ABS0; // ORA ABS,Y
                  8'h1A: state <= SYNC; // INC A
                  8'h1C: state <= ABS0; // TRB ABS
                  8'h1D: state <= ABS0; // ORA ABS,X
                  8'h1E: state <= ABS0; // ASL ABS,X
                  8'h20: state <= JSR0; // JSR
                  8'h21: state <= IDX0; // AND (ZP,X)
                  8'h24: state <= ZERO; // BIT ZP
                  8'h25: state <= ZERO; // AND ZP
                  8'h26: state <= ZERO; // ROL ZP
                  8'h28: state <= PLA0; // PLP
                  8'h29: state <= IMMI; // AND #IMM
                  8'h2A: state <= SYNC; // ROL A
                  8'h2C: state <= ABS0; // BIT ABS
                  8'h2D: state <= ABS0; // AND ABS
                  8'h2E: state <= ABS0; // ROL ABS
                  8'h30: state <= BRA0; // BMI
                  8'h31: state <= IDX0; // AND (ZP),Y
                  8'h32: state <= IDX0; // AND (ZP)
                  8'h34: state <= ZERO; // BIT ZP,X
                  8'h35: state <= ZERO; // AND ZP,X
                  8'h36: state <= ZERO; // ROL ZP,X
                  8'h38: state <= SYNC; // SEC
                  8'h39: state <= ABS0; // AND ABS,Y
                  8'h3A: state <= SYNC; // DEC A
                  8'h3C: state <= ABS0; // BIT ABS,X
                  8'h3D: state <= ABS0; // AND ABS,X
                  8'h3E: state <= ABS0; // ROL ABS,X
                  8'h40: state <= RTI0; // RTI
                  8'h41: state <= IDX0; // EOR (ZP,X)
                  8'h45: state <= ZERO; // EOR ZP
                  8'h46: state <= ZERO; // LSR ZP
                  8'h48: state <= PHA0; // PHA
                  8'h49: state <= IMMI; // EOR #IMM
                  8'h4A: state <= SYNC; // LSR A
                  8'h4C: state <= JMP0; // JMP
                  8'h4D: state <= ABS0; // EOR ABS
                  8'h4E: state <= ABS0; // LSR ABS
                  8'h50: state <= BRA0; // BVC
                  8'h51: state <= IDX0; // EOR (ZP),Y
                  8'h52: state <= IDX0; // EOR (ZP)
                  8'h55: state <= ZERO; // EOR ZP,X
                  8'h56: state <= ZERO; // LSR ZP,X
                  8'h58: state <= SYNC; // CLI
                  8'h59: state <= ABS0; // EOR ABS,Y
                  8'h5A: state <= PHA0; // PHY
                  8'h5D: state <= ABS0; // EOR ABS,X
                  8'h5E: state <= ABS0; // LSR ABS,X
                  8'h60: state <= RTS0; // RTS
                  8'h61: state <= IDX0; // ADC (ZP,X)
                  8'h64: state <= ZERO; // STZ ZP
                  8'h65: state <= ZERO; // ADC ZP
                  8'h66: state <= ZERO; // ROR ZP
                  8'h68: state <= PLA0; // PLA
                  8'h69: state <= IMMI; // ADC #IMM
                  8'h6A: state <= SYNC; // ROR A
                  8'h6C: state <= IND0; // JMP (IDX)
                  8'h6D: state <= ABS0; // ADC ABS
                  8'h6E: state <= ABS0; // ROR ABS
                  8'h70: state <= BRA0; // BVS
                  8'h71: state <= IDX0; // ADC (ZP),Y
                  8'h72: state <= IDX0; // ADC (ZP)
                  8'h74: state <= ZERO; // STZ ZP,X
                  8'h75: state <= ZERO; // ADC ZP,X
                  8'h76: state <= ZERO; // ROR ZP,X
                  8'h78: state <= SYNC; // SEI
                  8'h79: state <= ABS0; // ADC ABS,Y
                  8'h7A: state <= PLA0; // PLY
                  8'h7C: state <= IND0; // JMP (IDX,X)
                  8'h7D: state <= ABS0; // ADC ABS,X
                  8'h7E: state <= ABS0; // ROR ABS,X
                  8'h80: state <= BRA0; // BRA
                  8'h81: state <= IDX0; // STA (ZP,X)
                  8'h84: state <= ZERO; // STY ZP
                  8'h85: state <= ZERO; // STA ZP
                  8'h86: state <= ZERO; // STX ZP
                  8'h88: state <= SYNC; // DEY
                  8'h89: state <= IMMI; // BIT #IMM
                  8'h8A: state <= SYNC; // TXA
                  8'h8C: state <= ABS0; // STY ABS
                  8'h8D: state <= ABS0; // STA ABS
                  8'h8E: state <= ABS0; // STX ABS
                  8'h90: state <= BRA0; // BCC
                  8'h91: state <= IDX0; // STA (ZP),Y
                  8'h92: state <= IDX0; // STA (ZP)
                  8'h94: state <= ZERO; // STY ZP,X
                  8'h95: state <= ZERO; // STA ZP,X
                  8'h96: state <= ZERO; // STX ZP,Y
                  8'h98: state <= SYNC; // TYA
                  8'h99: state <= ABS0; // STA ABS,Y
                  8'h9A: state <= SYNC; // TXS
                  8'h9C: state <= ABS0; // STZ ABS
                  8'h9D: state <= ABS0; // STA ABS,X
                  8'h9E: state <= ABS0; // STZ ABS,X
                  8'hA0: state <= IMMI; // LDY #IMM
                  8'hA1: state <= IDX0; // LDA (ZP,X)
                  8'hA2: state <= IMMI; // LDX #IMM
                  8'hA4: state <= ZERO; // LDY ZP
                  8'hA5: state <= ZERO; // LDA ZP
                  8'hA6: state <= ZERO; // LDX ZP
                  8'hA8: state <= SYNC; // TAY
                  8'hA9: state <= IMMI; // LDA #IMM
                  8'hAA: state <= SYNC; // TAX
                  8'hAC: state <= ABS0; // LDY ABS
                  8'hAD: state <= ABS0; // LDA ABS
                  8'hAE: state <= ABS0; // LDX ABS
                  8'hB0: state <= BRA0; // BCS
                  8'hB1: state <= IDX0; // LDA (ZP),Y
                  8'hB2: state <= IDX0; // LDA (ZP)
                  8'hB4: state <= ZERO; // LDY ZP,X
                  8'hB5: state <= ZERO; // LDA ZP,X
                  8'hB6: state <= ZERO; // LDX ZP,Y
                  8'hB8: state <= SYNC; // CLV
                  8'hB9: state <= ABS0; // LDA ABS,Y
                  8'hBA: state <= SYNC; // TSX
                  8'hBC: state <= ABS0; // LDY ABS,X
                  8'hBD: state <= ABS0; // LDA ABS,X
                  8'hBE: state <= ABS0; // LDX ABS,Y
                  8'hC0: state <= IMMI; // CPY #IMM
                  8'hC1: state <= IDX0; // CMP (ZP,X)
                  8'hC4: state <= ZERO; // CPY ZP
                  8'hC5: state <= ZERO; // CMP ZP
                  8'hC6: state <= ZERO; // DEC ZP
                  8'hC8: state <= SYNC; // INY
                  8'hC9: state <= IMMI; // CMP #IMM
                  8'hCA: state <= SYNC; // DEX
                  8'hCC: state <= ABS0; // CPY ABS
                  8'hCD: state <= ABS0; // CMP ABS
                  8'hCE: state <= ABS0; // DEC ABS
                  8'hD0: state <= BRA0; // BNE
                  8'hD1: state <= IDX0; // CMP (ZP),Y
                  8'hD2: state <= IDX0; // CMP (ZP)
                  8'hD5: state <= ZERO; // CMP ZP,X
                  8'hD6: state <= ZERO; // DEC ZP,X
                  8'hD8: state <= SYNC; // CLD
                  8'hD9: state <= ABS0; // CMP ABS,Y
                  8'hDA: state <= PHA0; // PHX
                  8'hDD: state <= ABS0; // CMP ABS,X
                  8'hDE: state <= ABS0; // DEC ABS,X
                  8'hE0: state <= IMMI; // CPX #IMM
                  8'hE1: state <= IDX0; // SBC (ZP,X)
                  8'hE4: state <= ZERO; // CPX ZP
                  8'hE5: state <= ZERO; // SBC ZP
                  8'hE6: state <= ZERO; // INC ZP
                  8'hE8: state <= SYNC; // INX
                  8'hE9: state <= IMMI; // SBC #IMM
                  8'hEA: state <= SYNC; // NOP
                  8'hEC: state <= ABS0; // CPX ABS
                  8'hED: state <= ABS0; // SBC ABS
                  8'hEE: state <= ABS0; // INC ABS
                  8'hF0: state <= BRA0; // BEQ
                  8'hF1: state <= IDX0; // SBC (ZP),Y
                  8'hF2: state <= IDX0; // SBC (ZP)
                  8'hF5: state <= ZERO; // SBC ZP,X
                  8'hF6: state <= ZERO; // INC ZP,X
                  8'hF8: state <= SYNC; // SED
                  8'hF9: state <= ABS0; // SBC ABS,Y
                  8'hFA: state <= PLA0; // PLX
                  8'hFD: state <= ABS0; // SBC ABS,X
                  8'hFE: state <= ABS0; // INC ABS,X

               default:  state <= XXXX; // don't care;
               endcase

        IMMI:  state <= SYNC;
        PHA0:  state <= SYNC;
        PLA0:  state <= SYNC;
        ZERO:  state <= DATA;
        DATA:  state <= rmw ? RDWR : SYNC;
        ABS0:  state <= ABS1;
        ABS1:  state <= DATA;
        BRA0:  state <= SYNC;
        JSR0:  state <= JSR1;
        JSR1:  state <= JSR2;
        JSR2:  state <= JSR3;
        JSR3:  state <= SYNC;
        RTS0:  state <= RTS1;
        RTS1:  state <= RTS2;
        RTS2:  state <= SYNC;
        JMP0:  state <= JMP1;
        JMP1:  state <= SYNC;
        IDX0:  state <= IDX1;
        IDX1:  state <= IDX2;
        IDX2:  state <= DATA;
        RDWR:  state <= SYNC;
        BRK0:  state <= BRK1;
        BRK1:  state <= BRK2;
        BRK2:  state <= BRK3;
        BRK3:  state <= JMP0;
        RTI0:  state <= RTS0;
        IND0:  state <= IND1;
        IND1:  state <= JMP0;
        RST0:  state <= JMP0;
    endcase

/*
 * control vector
 */
always @(posedge clk)
    if( sync )
        case( IR )
             //                    +>=IDC_BVPIS_WSL_SR_DS ALU  IDX
             8'h6D: control <= 26'b0100000_000000_001_11_11_1001_00; // ADC ABS
             8'h7D: control <= 26'b0100000_000000_001_11_11_1001_01; // ADC ABS,X
             8'h79: control <= 26'b0100000_000000_001_11_11_1001_10; // ADC ABS,Y
             8'h69: control <= 26'b0100000_000000_001_11_11_1001_00; // ADC #IMM
             8'h65: control <= 26'b0100000_000000_001_11_11_1001_00; // ADC ZP
             8'h72: control <= 26'b0100000_000000_001_11_11_1001_00; // ADC (ZP)
             8'h61: control <= 26'b0100000_000000_001_11_11_1001_01; // ADC (ZP,X)
             8'h75: control <= 26'b0100000_000000_001_11_11_1001_01; // ADC ZP,X
             8'h71: control <= 26'b0100000_000000_001_11_11_1001_10; // ADC (ZP),Y

             8'hED: control <= 26'b0100000_000000_001_11_11_1010_00; // SBC ABS
             8'hFD: control <= 26'b0100000_000000_001_11_11_1010_01; // SBC ABS,X
             8'hF9: control <= 26'b0100000_000000_001_11_11_1010_10; // SBC ABS,Y
             8'hE9: control <= 26'b0100000_000000_001_11_11_1010_00; // SBC #IMM
             8'hE5: control <= 26'b0100000_000000_001_11_11_1010_00; // SBC ZP
             8'hF2: control <= 26'b0100000_000000_001_11_11_1010_00; // SBC (ZP)
             8'hE1: control <= 26'b0100000_000000_001_11_11_1010_01; // SBC (ZP,X)
             8'hF5: control <= 26'b0100000_000000_001_11_11_1010_01; // SBC ZP,X
             8'hF1: control <= 26'b0100000_000000_001_11_11_1010_10; // SBC (ZP),Y

             8'h2D: control <= 26'b0000000_000000_001_11_11_0111_00; // AND ABS
             8'h3D: control <= 26'b0000000_000000_001_11_11_0111_01; // AND ABS,X
             8'h39: control <= 26'b0000000_000000_001_11_11_0111_10; // AND ABS,Y
             8'h29: control <= 26'b0000000_000000_001_11_11_0111_00; // AND #IMM
             8'h25: control <= 26'b0000000_000000_001_11_11_0111_00; // AND ZP
             8'h32: control <= 26'b0000000_000000_001_11_11_0111_00; // AND (ZP)
             8'h21: control <= 26'b0000000_000000_001_11_11_0111_01; // AND (ZP,X)
             8'h35: control <= 26'b0000000_000000_001_11_11_0111_01; // AND ZP,X
             8'h31: control <= 26'b0000000_000000_001_11_11_0111_10; // AND (ZP),Y

             8'h0D: control <= 26'b0000000_000000_001_11_11_0110_00; // ORA ABS
             8'h1D: control <= 26'b0000000_000000_001_11_11_0110_01; // ORA ABS,X
             8'h19: control <= 26'b0000000_000000_001_11_11_0110_10; // ORA ABS,Y
             8'h09: control <= 26'b0000000_000000_001_11_11_0110_00; // ORA #IMM
             8'h05: control <= 26'b0000000_000000_001_11_11_0110_00; // ORA ZP
             8'h12: control <= 26'b0000000_000000_001_11_11_0110_00; // ORA (ZP)
             8'h01: control <= 26'b0000000_000000_001_11_11_0110_01; // ORA (ZP,X)
             8'h15: control <= 26'b0000000_000000_001_11_11_0110_01; // ORA ZP,X
             8'h11: control <= 26'b0000000_000000_001_11_11_0110_10; // ORA (ZP),Y

             8'hAD: control <= 26'b0000000_000000_001_11_11_0011_00; // LDA ABS
             8'hBD: control <= 26'b0000000_000000_001_11_11_0011_01; // LDA ABS,X
             8'hB9: control <= 26'b0000000_000000_001_11_11_0011_10; // LDA ABS,Y
             8'hA9: control <= 26'b0000000_000000_001_11_11_0011_00; // LDA #IMM
             8'hA5: control <= 26'b0000000_000000_001_11_11_0011_00; // LDA ZP
             8'hB2: control <= 26'b0000000_000000_001_11_11_0011_00; // LDA (ZP)
             8'hA1: control <= 26'b0000000_000000_001_11_11_0011_01; // LDA (ZP,X)
             8'hB5: control <= 26'b0000000_000000_001_11_11_0011_01; // LDA ZP,X
             8'hB1: control <= 26'b0000000_000000_001_11_11_0011_10; // LDA (ZP),Y

             8'hCD: control <= 26'b0001000_000000_000_11_11_1101_00; // CMP ABS
             8'hDD: control <= 26'b0001000_000000_000_11_11_1101_01; // CMP ABS,X
             8'hD9: control <= 26'b0001000_000000_000_11_11_1101_10; // CMP ABS,Y
             8'hC9: control <= 26'b0001000_000000_000_11_11_1101_00; // CMP #IMM
             8'hC5: control <= 26'b0001000_000000_000_11_11_1101_00; // CMP ZP
             8'hD2: control <= 26'b0001000_000000_000_11_11_1101_00; // CMP (ZP)
             8'hC1: control <= 26'b0001000_000000_000_11_11_1101_01; // CMP (ZP,X)
             8'hD5: control <= 26'b0001000_000000_000_11_11_1101_01; // CMP ZP,X
             8'hD1: control <= 26'b0001000_000000_000_11_11_1101_10; // CMP (ZP),Y

             8'h4D: control <= 26'b0000000_000000_001_11_11_1000_00; // EOR ABS
             8'h5D: control <= 26'b0000000_000000_001_11_11_1000_01; // EOR ABS,X
             8'h59: control <= 26'b0000000_000000_001_11_11_1000_10; // EOR ABS,Y
             8'h49: control <= 26'b0000000_000000_001_11_11_1000_00; // EOR #IMM
             8'h45: control <= 26'b0000000_000000_001_11_11_1000_00; // EOR ZP
             8'h52: control <= 26'b0000000_000000_001_11_11_1000_00; // EOR (ZP)
             8'h41: control <= 26'b0000000_000000_001_11_11_1000_01; // EOR (ZP,X)
             8'h55: control <= 26'b0000000_000000_001_11_11_1000_01; // EOR ZP,X
             8'h51: control <= 26'b0000000_000000_001_11_11_1000_10; // EOR (ZP),Y

             8'h8D: control <= 26'b0000000_000000_010_11_11_0011_00; // STA ABS
             8'h9D: control <= 26'b0000000_000000_010_11_11_0011_01; // STA ABS,X
             8'h99: control <= 26'b0000000_000000_010_11_11_0011_10; // STA ABS,Y
             8'h85: control <= 26'b0000000_000000_010_11_11_0011_00; // STA ZP
             8'h92: control <= 26'b0000000_000000_010_11_11_0011_00; // STA (ZP)
             8'h81: control <= 26'b0000000_000000_010_11_11_0011_01; // STA (ZP,X)
             8'h95: control <= 26'b0000000_000000_010_11_11_0011_01; // STA ZP,X
             8'h91: control <= 26'b0000000_000000_010_11_11_0011_10; // STA (ZP),Y

             8'h0A: control <= 26'b0010000_000000_001_11_11_1011_00; // ASL A
             8'h0E: control <= 26'b0010000_000000_100_00_00_1011_00; // ASL ABS
             8'h1E: control <= 26'b0010000_000000_100_00_00_1011_01; // ASL ABS,X
             8'h06: control <= 26'b0010000_000000_100_00_00_1011_00; // ASL ZP
             8'h16: control <= 26'b0010000_000000_100_00_00_1011_01; // ASL ZP,X

             8'h4A: control <= 26'b0010000_000000_001_11_11_1100_00; // LSR A
             8'h4E: control <= 26'b0010000_000000_100_00_00_1100_00; // LSR ABS
             8'h5E: control <= 26'b0010000_000000_100_00_00_1100_01; // LSR ABS,X
             8'h46: control <= 26'b0010000_000000_100_00_00_1100_00; // LSR ZP
             8'h56: control <= 26'b0010000_000000_100_00_00_1100_01; // LSR ZP,X

             8'h2A: control <= 26'b1010000_000000_001_11_11_1011_00; // ROL A
             8'h2E: control <= 26'b1010000_000000_100_00_00_1011_00; // ROL ABS
             8'h3E: control <= 26'b1010000_000000_100_00_00_1011_01; // ROL ABS,X
             8'h26: control <= 26'b1010000_000000_100_00_00_1011_00; // ROL ZP
             8'h36: control <= 26'b1010000_000000_100_00_00_1011_01; // ROL ZP,X

             8'h6A: control <= 26'b1010000_000000_001_11_11_1100_00; // ROR A
             8'h6E: control <= 26'b1010000_000000_100_00_00_1100_00; // ROR ABS
             8'h7E: control <= 26'b1010000_000000_100_00_00_1100_01; // ROR ABS,X
             8'h66: control <= 26'b1010000_000000_100_00_00_1100_00; // ROR ZP
             8'h76: control <= 26'b1010000_000000_100_00_00_1100_01; // ROR ZP,X

             8'h90: control <= 26'b0000000_000000_000_00_00_0000_00; // BCC
             8'hB0: control <= 26'b0000000_000000_000_00_00_0000_00; // BCS
             8'hF0: control <= 26'b0000000_000000_000_00_00_0000_00; // BEQ
             8'h30: control <= 26'b0000000_000000_000_00_00_0000_00; // BMI
             8'hD0: control <= 26'b0000000_000000_000_00_00_0000_00; // BNE
             8'h10: control <= 26'b0000000_000000_000_00_00_0000_00; // BPL
             8'h80: control <= 26'b0000000_000000_000_00_00_0000_00; // BRA
             8'h00: control <= 26'b0000000_000000_000_00_00_0000_00; // BRK
             8'h50: control <= 26'b0000000_000000_000_00_00_0000_00; // BVC
             8'h70: control <= 26'b0000000_000000_000_00_00_0000_00; // BVS

             8'h2C: control <= 26'b0000000_100000_000_11_11_0111_00; // BIT ABS
             8'h3C: control <= 26'b0000000_100000_000_11_11_0111_01; // BIT ABS,X
             8'h89: control <= 26'b0000000_100000_000_11_11_0111_00; // BIT #IMM
             8'h24: control <= 26'b0000000_100000_000_11_11_0111_00; // BIT ZP
             8'h34: control <= 26'b0000000_100000_000_11_11_0111_01; // BIT ZP,X

             8'h18: control <= 26'b0000001_000000_000_00_00_0000_00; // CLC
             8'hD8: control <= 26'b0000010_000000_000_00_00_0000_00; // CLD
             8'h58: control <= 26'b0000100_000000_000_00_00_0000_00; // CLI
             8'hB8: control <= 26'b0000000_010000_000_00_00_0000_00; // CLV
             8'h38: control <= 26'b0000001_000000_000_00_00_0000_00; // SEC
             8'hF8: control <= 26'b0000010_000000_000_00_00_0000_00; // SED
             8'h78: control <= 26'b0000100_000000_000_00_00_0000_00; // SEI

             8'hEC: control <= 26'b0001000_000000_000_01_01_1101_00; // CPX ABS
             8'hE0: control <= 26'b0001000_000000_000_01_01_1101_00; // CPX #IMM
             8'hE4: control <= 26'b0001000_000000_000_01_01_1101_00; // CPX ZP

             8'hCC: control <= 26'b0001000_000000_000_10_10_1101_00; // CPY ABS
             8'hC0: control <= 26'b0001000_000000_000_10_10_1101_00; // CPY #IMM
             8'hC4: control <= 26'b0001000_000000_000_10_10_1101_00; // CPY ZP

             8'h3A: control <= 26'b0000000_000000_001_11_11_0010_00; // DEC A
             8'hCE: control <= 26'b0000000_000000_100_00_00_0010_00; // DEC ABS
             8'hDE: control <= 26'b0000000_000000_100_00_00_0010_01; // DEC ABS,X
             8'hC6: control <= 26'b0000000_000000_100_00_00_0010_00; // DEC ZP
             8'hD6: control <= 26'b0000000_000000_100_00_00_0010_01; // DEC ZP,X

             8'h1A: control <= 26'b0000000_000000_001_11_11_0001_00; // INC A
             8'hEE: control <= 26'b0000000_000000_100_00_00_0001_00; // INC ABS
             8'hFE: control <= 26'b0000000_000000_100_00_00_0001_01; // INC ABS,X
             8'hE6: control <= 26'b0000000_000000_100_00_00_0001_00; // INC ZP
             8'hF6: control <= 26'b0000000_000000_100_00_00_0001_01; // INC ZP,X

             8'hCA: control <= 26'b0000000_000000_001_01_01_0010_00; // DEX
             8'h88: control <= 26'b0000000_000000_001_10_10_0010_00; // DEY
             8'hE8: control <= 26'b0000000_000000_001_01_01_0001_00; // INX
             8'hC8: control <= 26'b0000000_000000_001_10_10_0001_00; // INY
             8'hAA: control <= 26'b0000000_000000_001_11_01_0000_00; // TAX
             8'hA8: control <= 26'b0000000_000000_001_11_10_0000_00; // TAY
             8'hBA: control <= 26'b0000000_000000_001_00_01_0100_00; // TSX
             8'h8A: control <= 26'b0000000_000000_001_01_11_0000_00; // TXA
             8'h9A: control <= 26'b0000000_000001_000_00_00_0000_00; // TXS
             8'h98: control <= 26'b0000000_000000_001_10_11_0000_00; // TYA
             8'hEA: control <= 26'b0000000_000000_000_00_00_0000_00; // NOP

             8'h4C: control <= 26'b0000000_000000_000_00_00_0000_00; // JMP
             8'h6C: control <= 26'b0000000_000000_000_00_00_0000_00; // JMP (IDX)
             8'h7C: control <= 26'b0000000_000000_000_00_00_0000_01; // JMP (IDX,X)
             8'h20: control <= 26'b0000000_000000_000_00_00_0000_00; // JSR
             8'h40: control <= 26'b0000000_000010_000_00_00_0000_00; // RTI
             8'h60: control <= 26'b0000000_000000_000_00_00_0000_00; // RTS

             8'hAE: control <= 26'b0000000_000000_001_00_01_0011_00; // LDX ABS
             8'hBE: control <= 26'b0000000_000000_001_00_01_0011_10; // LDX ABS,Y
             8'hA2: control <= 26'b0000000_000000_001_00_01_0011_00; // LDX #IMM
             8'hA6: control <= 26'b0000000_000000_001_00_01_0011_00; // LDX ZP
             8'hB6: control <= 26'b0000000_000000_001_00_01_0011_10; // LDX ZP,Y
             8'hAC: control <= 26'b0000000_000000_001_00_10_0011_00; // LDY ABS
             8'hBC: control <= 26'b0000000_000000_001_00_10_0011_01; // LDY ABS,X
             8'hA0: control <= 26'b0000000_000000_001_00_10_0011_00; // LDY #IMM
             8'hA4: control <= 26'b0000000_000000_001_00_10_0011_00; // LDY ZP
             8'hB4: control <= 26'b0000000_000000_001_00_10_0011_01; // LDY ZP,X

             8'h48: control <= 26'b0000000_000000_000_11_00_0011_00; // PHA
             8'h08: control <= 26'b0000000_001000_000_00_00_0000_00; // PHP
             8'hDA: control <= 26'b0000000_000000_000_01_00_0011_00; // PHX
             8'h5A: control <= 26'b0000000_000000_000_10_00_0011_00; // PHY
             8'h68: control <= 26'b0000000_000000_001_00_11_0101_00; // PLA
             8'h28: control <= 26'b0000000_000100_000_00_00_0000_00; // PLP
             8'hFA: control <= 26'b0000000_000000_001_00_01_0101_00; // PLX
             8'h7A: control <= 26'b0000000_000000_000_00_10_0101_00; // PLY

             8'h8E: control <= 26'b0000000_000000_010_01_00_0011_00; // STX ABS
             8'h86: control <= 26'b0000000_000000_010_01_00_0011_00; // STX ZP
             8'h96: control <= 26'b0000000_000000_010_01_00_0011_10; // STX ZP,Y
             8'h8C: control <= 26'b0000000_000000_010_10_00_0011_00; // STY ABS
             8'h84: control <= 26'b0000000_000000_010_10_00_0011_00; // STY ZP
             8'h94: control <= 26'b0000000_000000_010_10_00_0011_01; // STY ZP,X

             8'h9C: control <= 26'b0000000_000000_010_00_00_0011_00; // STZ ABS
             8'h9E: control <= 26'b0000000_000000_010_00_00_0011_01; // STZ ABS,X
             8'h64: control <= 26'b0000000_000000_010_00_00_0011_00; // STZ ZP
             8'h74: control <= 26'b0000000_000000_010_00_00_0011_01; // STZ ZP,X

             8'h1C: control <= 26'b0000000_000000_000_00_00_0000_00; // TRB ABS
             8'h14: control <= 26'b0000000_000000_000_00_00_0000_00; // TRB ZP
             8'h0C: control <= 26'b0000000_000000_000_00_00_0000_00; // TSB ABS
             8'h04: control <= 26'b0000000_000000_000_00_00_0000_00; // TSB ZP
           default: control <= 26'bxxxxxxx_xxxxxx_xxx_xx_xx_xxxx_xx; 
        endcase
/*
 *****************************************************************************
 * debug section
 *****************************************************************************
 */

`ifdef SIM

reg [39:0] statename;
always @*
    case( state )
        SYNC: statename = "SYNC";
        IMMI: statename = "IMMI";
        PHA0: statename = "PHA0";
        PLA0: statename = "PLA0";
        ZERO: statename = "ZERO";
        DATA: statename = "DATA";
        ABS0: statename = "ABS0";
        ABS1: statename = "ABS1";
        BRA0: statename = "BRA0";
        IND0: statename = "IND0";
        IND1: statename = "IND1";
        JMP0: statename = "JMP0";
        JMP1: statename = "JMP1";
        JSR0: statename = "JSR0";
        JSR1: statename = "JSR1";
        JSR2: statename = "JSR2";
        JSR3: statename = "JSR3";
        RTS0: statename = "RTS0";
        RTS1: statename = "RTS1";
        RTS2: statename = "RTS2";
        IDX0: statename = "IDX0";
        IDX1: statename = "IDX1";
        IDX2: statename = "IDX2";
        RDWR: statename = "RDWR";
        BRK0: statename = "BRK0";
        BRK1: statename = "BRK1";
        BRK2: statename = "BRK2";
        BRK3: statename = "BRK3";
        RTI0: statename = "RTI0";
    default : statename = "?";
    endcase

reg [7:0] instruction;
reg [23:0] opcode;

always @*
    casez( instruction )
            8'b0000_0000: opcode = "BRK";
            8'b0000_1000: opcode = "PHP";
            8'b0001_0010: opcode = "ORA";
            8'b0011_0010: opcode = "AND";
            8'b0101_0010: opcode = "EOR";
            8'b0111_0010: opcode = "ADC";
            8'b1001_0010: opcode = "STA";
            8'b1011_0010: opcode = "LDA";
            8'b1101_0010: opcode = "CMP";
            8'b1111_0010: opcode = "SBC";
            8'b011?_0100: opcode = "STZ";
            8'b1001_11?0: opcode = "STZ";
            8'b0101_1010: opcode = "PHY";
            8'b1101_1010: opcode = "PHX";
            8'b0111_1010: opcode = "PLY";
            8'b1111_1010: opcode = "PLX";
            8'b000?_??01: opcode = "ORA";
            8'b0001_0000: opcode = "BPL";
            8'b0001_1010: opcode = "INA";
            8'b000?_??10: opcode = "ASL";
            8'b0001_1000: opcode = "CLC";
            8'b0010_0000: opcode = "JSR";
            8'b0010_1000: opcode = "PLP";
            8'b001?_?100: opcode = "BIT";
            8'b1000_1001: opcode = "BIT";
            8'b001?_??01: opcode = "AND";
            8'b0011_0000: opcode = "BMI";
            8'b0011_1010: opcode = "DEA";
            8'b001?_??10: opcode = "ROL";
            8'b0011_1000: opcode = "SEC";
            8'b0100_0000: opcode = "RTI";
            8'b0100_1000: opcode = "PHA";
            8'b010?_??01: opcode = "EOR";
            8'b0101_0000: opcode = "BVC";
            8'b010?_??10: opcode = "LSR";
            8'b0101_1000: opcode = "CLI";
            8'b01??_1100: opcode = "JMP";
            8'b0110_0000: opcode = "RTS";
            8'b0110_1000: opcode = "PLA";
            8'b011?_??01: opcode = "ADC";
            8'b0111_0000: opcode = "BVS";
            8'b011?_??10: opcode = "ROR";
            8'b0111_1000: opcode = "SEI";
            8'b1000_0000: opcode = "BRA";
            8'b1000_1000: opcode = "DEY";
            8'b1000_?100: opcode = "STY";
            8'b1001_0100: opcode = "STY";
            8'b1000_1010: opcode = "TXA";
            8'b1001_0010: opcode = "STA";
            8'b100?_??01: opcode = "STA";
            8'b1001_0000: opcode = "BCC";
            8'b1001_1000: opcode = "TYA";
            8'b1001_1010: opcode = "TXS";
            8'b100?_?110: opcode = "STX";
            8'b1010_0000: opcode = "LDY";
            8'b1010_1000: opcode = "TAY";
            8'b1010_1010: opcode = "TAX";
            8'b101?_??01: opcode = "LDA";
            8'b1011_0000: opcode = "BCS";
            8'b101?_?100: opcode = "LDY";
            8'b1011_1000: opcode = "CLV";
            8'b1011_1010: opcode = "TSX";
            8'b101?_?110: opcode = "LDX";
            8'b1010_0010: opcode = "LDX";
            8'b1100_0000: opcode = "CPY";
            8'b1100_1000: opcode = "INY";
            8'b1100_?100: opcode = "CPY";
            8'b1100_1010: opcode = "DEX";
            8'b110?_??01: opcode = "CMP";
            8'b1101_0000: opcode = "BNE";
            8'b1101_1000: opcode = "CLD";
            8'b110?_?110: opcode = "DEC";
            8'b1110_0000: opcode = "CPX";
            8'b1110_1000: opcode = "INX";
            8'b1110_?100: opcode = "CPX";
            8'b1110_1010: opcode = "NOP";
            8'b111?_??01: opcode = "SBC";
            8'b1111_0000: opcode = "BEQ";
            8'b1111_1000: opcode = "SED";
            8'b111?_?110: opcode = "INC";
            8'b1101_1011: opcode = "STP";
            8'b0000_?100: opcode = "TSB";
            8'b0001_?100: opcode = "TRB";

            default:      opcode = "___";
    endcase

wire [7:0] R_ = RST ? "R" : "-";

integer cycle;

always @( posedge clk )
    if( sync )
        instruction <= IR;

always @( posedge clk )
    cycle <= cycle + 1;

wire [7:0] B_ = B ? "B" : "-";
wire [7:0] C_ = C ? "C" : "-";
wire [7:0] D_ = D ? "D" : "-";
wire [7:0] I_ = I ? "I" : "-";
wire [7:0] N_ = N ? "N" : "-";
wire [7:0] V_ = V ? "V" : "-";
wire [7:0] Z_ = Z ? "Z" : "-";

wire [7:0] X = regs[SEL_X];
wire [7:0] Y = regs[SEL_Y];
wire [7:0] A = regs[SEL_A];

always @( posedge clk ) begin
    if( !debug || cycle < 150000 || cycle[10:0] == 0 )
      $display( "%4d %s %s %s PC:%h AD:%h DB:%h HOLD:%h DO:%h AHL:%h IR:%h WE:%d ALU:%h S:%02x A:%h X:%h Y:%h R:%h M:%h LD:%h P:%s%s1%s%s%s%s%s %d", 
                 cycle, R_, opcode, statename, PC, AD, DB, DBHOLD, DO, AHL, IR, WE, alu_out, S, A, X, Y, R, M, ld, N_, V_, B_, D_, I_, Z_, C_, alu_C );
      if( instruction == 8'hdb )
        $finish( );
end
`endif

endmodule