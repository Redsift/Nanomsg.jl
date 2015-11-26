# Julia Nanomsg Bindings

For v0.4.x

### Constants

Nanomsg.jl uses the nn_symbol_info() native function to load the available string constants and the corresponding values. This is then used to populate the baremodule CSymbols. You may view the generated constants for debug purposes with a generated String object J_NN_ALL. e.g. `println("Symbol tree:", CSymbols.J_NN_ALL)` 

You also also use the `J_NN_MAP` constant to access a Cint indexed dictionary structure mapping the namespace number to another Cint indexed number/string pair.