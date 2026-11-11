# Scan.Stitch (__init__.py): chains in placement order, SCAN_MAX_CHAINS of
# them, one scan enable; adds the ports. The plan is in the step's log.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read_current_odb

log_cmd set_dft_config -max_chains $::env(SCAN_MAX_CHAINS) -clock_mixing clock_mix
report_dft_config
log_cmd report_dft_plan -verbose
log_cmd execute_dft_plan

# execute_dft_plan leaves the new ports' type unset: the LEF written later
# then says "USE ;", which OpenDB's own LEF reader rejects (LEFPARS-1 in
# Odb.CheckDesignAntennaProperties). They are signals.
foreach bt [$::block getBTerms] {
    if { [string match scan_* [$bt getName]] && [$bt getSigType] ne "SIGNAL" } {
        puts "\[INFO\] [$bt getName]: [$bt getSigType] -> SIGNAL"
        $bt setSigType SIGNAL
        [$bt getNet] setSigType SIGNAL
    }
}

write_views
