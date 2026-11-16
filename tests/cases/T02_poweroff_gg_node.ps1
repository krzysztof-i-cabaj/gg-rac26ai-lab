# ==============================================================================
# Tytul:        T02_poweroff_gg_node.ps1
# Opis:         Definicja testu T2 (Hard power-off of the GoldenGate node) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T2 (Hard power-off of the GoldenGate node) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T2
# Usage [EN]:        .\tests\run_test.ps1 -Test T2
# ==============================================================================
@{
    Id          = 'T2'
    Title       = 'Hard power-off of the GoldenGate node'
    Kind        = 'poweroff'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac1'
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 900            # give up waiting for recovery
    Notes       = 'Start ggrac1 again before T2-back.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'hands-off recovery: eviction, service to ggcdb2, ACFS, VIP, Service Manager, Extract reads the redo of thread 1'
        Source     = 'lab verification report, MAA 26ai (GG follows the singleton PDB service)'
        FinalNode  = 'ggrac2'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
