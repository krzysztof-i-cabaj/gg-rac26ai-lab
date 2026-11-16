# ==============================================================================
# Tytul:        T01_relocate.ps1
# Opis:         Definicja testu T1 (Planned relocation) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T1 (Planned relocation) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T1
# Usage [EN]:        .\tests\run_test.ps1 -Test T1
# ==============================================================================
@{
    Id          = 'T1'
    Title       = 'Planned relocation'
    Kind        = 'relocate'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac2'
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 600            # give up waiting for recovery
    Notes       = 'Check whether agctl relocate moved gg_srcpdb (notes).'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'XAG chain in order (SM stop, ACFS off node 1, mount on ggrac2, VIP, start, processes from checkpoints); does agctl relocate move gg_srcpdb?'
        Source     = 'MAA 26ai (agctl relocate), lab verification report'
        FinalNode  = 'ggrac2'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
