# Checks that constr/accel_cdc.xdc found what it constrains, for any flow
# that read it (syn/synth_ooc.tcl, syn/impl_arty.tcl). XDC has no error
# command: a constraint whose cell search found nothing applies to nothing,
# silently.
foreach f {u_in u_out} {
    foreach sync {u_wptr_sync u_rptr_sync} {
        set pat "*u_seq/g_cdc.$f/$sync/sync_q_reg*"
        if {[llength [get_cells -hier -filter "NAME =~ $pat"]] == 0} {
            error "accel_cdc.xdc: nothing matches $pat"
        }
    }
    if {[llength [get_cells -hier -filter "NAME =~ *u_seq/g_cdc.$f/mem_reg* && PRIMITIVE_GROUP == DMEM"]] == 0} {
        error "accel_cdc.xdc: no distributed RAM in $f"
    }
}
if {[llength [get_pins -hier -filter {NAME =~ *g_rst_cdc.u_rst_*/sync_q_reg*/PRE}]] != 4} {
    error "accel_cdc.xdc: expected 4 reset synchronizer PRE pins"
}
