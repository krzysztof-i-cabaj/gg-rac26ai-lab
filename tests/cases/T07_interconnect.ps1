# ==============================================================================
# Tytul:        T07_interconnect.ps1
# Opis:         Definicja testu T7 (Interconnect cut) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T7 (Interconnect cut) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T7
# Usage [EN]:        .\tests\run_test.ps1 -Test T7
# ==============================================================================
@{
    Id          = 'T7'
    Title       = 'Interconnect cut'
    Kind        = 'link-down'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac2'
    Destructive = $true      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 180            # observation after t_lag_ok
    TimeoutSec  = 1200            # give up waiting for recovery
    Notes       = 'setlinkstate3 on afterwards; record evicted_node.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'exactly one node leaves the cluster (which one: measured), GoldenGate ends on the node that stays, replication comes back'
        Source     = 'lab verification report, lab plan'
        FinalNode  = 'nie wiemy'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
