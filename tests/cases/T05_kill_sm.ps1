# ==============================================================================
# Tytul:        T05_kill_sm.ps1
# Opis:         Definicja testu T5 (Kill the Service Manager) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T5 (Kill the Service Manager) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T5
# Usage [EN]:        .\tests\run_test.ps1 -Test T5
# ==============================================================================
@{
    Id          = 'T5'
    Title       = 'Kill the Service Manager'
    Kind        = 'kill-sm'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac1'
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 600            # give up waiting for recovery
    Notes       = 'Record what XAG did: restart in place or relocate.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'XAG/CRS sees the missing process and restarts the deployment in place or moves it to the other node'
        Source     = 'lab verification report; bug 37468391 needs more than one Service Manager (we have one)'
        FinalNode  = 'nie wiemy'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
