# ⚙️ SETTINGS — gg-rac26ai-lab

[![Project](https://img.shields.io/badge/Project-gg--rac26ai--lab-blue)]()
[![Config](https://img.shields.io/badge/Config-lab.config.psd1-blueviolet)]()
[![Secrets](https://img.shields.io/badge/Secrets-LAB__PASS-red)]()

> 🎯 **PL:** Jedno źródło prawdy o konwencjach tego projektu. **EN:** Single source of truth for this project's conventions.
> Plik dwujęzyczny / bilingual file.

## 📁 `<repo>`

`<repo>` = katalog główny projektu, tam gdzie sklonowano repo / project root, where you cloned it (np. / e.g. `D:\labs\gg-rac26ai-lab`).
Cała konfiguracja labu jest w `<repo>/lab.config.psd1` (maszyny, sieć, dyski, binaria, nazwy) /
the whole lab configuration lives in `<repo>/lab.config.psd1` (VMs, network, disks, binaries, names).

## 📤 Kopiowanie na maszyny / Copying to VMs

`lab.ps1` sam kopiuje pliki na maszyny jako root do `/root/lab/` i uruchamia je stamtąd (`Sync-Guest`): `guest/lib.sh`,
`guest/run_step.sh`, katalog roli (`guest/infra|rac|tgt`), `guest/shared`, `sql/`, `ogg/` i wygenerowane pliki węzła z
`guest/out/<vm>/` (`lab.env`, `hosts.env`, pliki odpowiedzi bez haseł). Ręcznie (droga bez `lab.cmd`) /
`lab.ps1` copies the files to `/root/lab/` as root and runs them from there; by hand:

```powershell
scp -r <repo>/guest/lib.sh <repo>/guest/run_step.sh <repo>/guest/rac <repo>/guest/shared root@192.168.58.11:/root/lab/
scp -r <repo>/sql <repo>/ogg root@192.168.58.11:/root/lab/
scp <repo>/guest/out/ggrac1/* root@192.168.58.11:/root/lab/     # lab.env, hosts.env, *.rsp, *.oby (written by every guest step)
```

Oracle ZIP-y trafiają do `/u01/stage` (spacje w nazwach zamienione na `_`) / Oracle ZIPs go to `/u01/stage`
(spaces in names replaced by `_`).

## 🔐 Hasło / Secrets — `LAB_PASS`

- Źródło prawdy: zmienna `$env:LAB_PASS` na hoście (co najmniej 8 znaków: litery, cyfry, `_`) / source of truth: the
  host variable `$env:LAB_PASS` (at least 8 letters, digits or `_`). Nigdy w repozytorium / never in the repository.
- Kickstart (`kickstart/base.ks.tmpl` i `role-*.ks.tmpl`, `%post`) zapisuje ją jako `export LAB_PASS=...` w
  `/root/.lab_secrets` oraz w `~/.lab_secrets` użytkowników `grid` i `oracle` (chmod 600, właściciel = użytkownik); ten sam
  plik renderowany na hoście (`kickstart/out/*.ks`) jest usuwany po instalacji / the kickstart writes it to these 600 files;
  the rendered kickstart on the host is deleted after the install.
- Skrypty biorą hasło tylko z `$LAB_PASS`; nigdy z argv, z repo ani z plików `.prm` (GoldenGate: `USERIDALIAS`).
  Pliki odpowiedzi i SQL mają znaczniki `@@LAB_PASS@@`, wypełniane na maszynie w kopii 600 (`render_secret`) /
  scripts read only `$LAB_PASS`; templates carry `@@LAB_PASS@@`, filled on the VM into a 600 copy.
- Ręcznie na maszynie / by hand on a VM: `echo "export LAB_PASS='...'" > ~/.lab_secrets && chmod 600 ~/.lab_secrets`.
- Administrator GoldenGate (`oggadmin`): `ogg_admin_pass` w `guest/lib.sh` = `LAB_PASS` + brakujące klasy znaków
  (`_`, `A`, `a`, `1`) wymagane przez politykę silnych haseł GoldenGate 23.26 (INS-85080); maks. 30 znaków /
  `LAB_PASS` plus the character classes GoldenGate 23.26 requires; at most 30 characters.

## 🔗 Referencje / References

| Plik / File | Opis / Description |
|---|---|
| `README.md` / `README_PL.md` | opis, wymagania, szybki start / overview, requirements, quick start |
| `DESIGN.md` / `DESIGN_PL.md` | decyzje (ADR), zgodność wersji, bezpieczeństwo / decisions, version compatibility, security |
| `docs/ENVIRONMENT*.md` | maszyny, sieci, dyski, wersje, host / VMs, networks, disks, versions, host |
| `docs/INSTALL_AUTO*.md`, `docs/INSTALL_STEPWISE*.md`, `docs/MANUAL*.md` | trzy drogi instalacji / the three installation paths |
| `docs/OPERATIONS*.md` | obsługa, stan bazowy, wyłączanie, problemy / operations, base state, shutdown, troubleshooting |
| `docs/PITFALLS_26AI*.md`, `docs/TIMINGS*.md` | pułapki 26ai, czasy kroków / 26ai pitfalls, step durations |
| `TESTS.md` / `TESTS_PL.md`, `docs/RESULTS*.md` | testy awarii T1–T10 i wyniki / failure tests and results |
| `tests/static/Test-Static.ps1` | testy bez maszyn / tests without VMs |
