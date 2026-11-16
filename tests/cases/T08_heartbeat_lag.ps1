# ==============================================================================
# Tytul:        T08_heartbeat_lag.ps1
# Opis:         Definicja testu T8 (Lag through heartbeat) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T8 (Lag through heartbeat) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T8
# Usage [EN]:        .\tests\run_test.ps1 -Test T8
# ==============================================================================
@{
    Id          = 'T8'
    Title       = 'Lag through heartbeat'
    Kind        = 'none'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = ''
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $false      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 600            # observation after t_lag_ok
    TimeoutSec  = 900            # give up waiting for recovery
    Notes       = 'Baseline under load, 10 minutes.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'lag under load a few seconds, always below 30 s; rows of INST 1 and 2 reach the target (Extract reads both threads)'
        Source     = 'lab verification report, film concept note; no THREADS option in ADD EXTRACT (GG 26 docs)'
        FinalNode  = 'ggrac1'      # GoldenGate node at the end
        Recovers   = 'nie dotyczy'       # recovers without a human
        RtoS       = 'nie dotyczy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
