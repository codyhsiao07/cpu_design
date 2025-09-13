// 1-bit Full Adder
// Inputs:  a, b, cin
// Outputs: sum, cout

module full_adder (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);
    // Behavioral implementation using vector concatenation
    // Equivalent to:
    //   assign sum  = a ^ b ^ cin;
    //   assign cout = (a & b) | (a & cin) | (b & cin);
    assign {cout, sum} = a + b + cin;
endmodule