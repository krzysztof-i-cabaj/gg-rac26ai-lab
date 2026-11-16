# ==============================================================================
# Tytul:        T03_poweroff_second_node.ps1
# Opis:         Definicja testu T3 (Power-off of the second node) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T3 (Power-off of the second node) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T3
# Usage [EN]:        .\tests\run_test.ps1 -Test T3
# ==============================================================================
@{
    Id          = 'T3'
    Title       = 'Power-off of the second node'
    Kind        = 'poweroff'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac2'
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $false      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 300            # observation after t_lag_ok
    TimeoutSec  = 600            # give up waiting for recovery
    Notes       = 'GoldenGate should stay on ggrac1; record lag_jump.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'GoldenGate stays on ggrac1; at most a short lag jump until thread 2 is closed; every INST=2 row committed before the fault reaches the target'
        Source     = 'lab verification report'
        FinalNode  = 'ggrac1'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
