// gg-rac26ai-lab - GitHub Pages helper (no external code).
// Links to repository files are built here, so the GitHub owner lives in ONE place.
// On <owner>.github.io the owner is taken from the host name; GH_OWNER is the fallback
// for any other host (local preview, custom domain). Set it before publishing.
(function () {
  "use strict";
  var GH_OWNER = "OWNER";           // <-- set to the GitHub user or organisation
  var GH_REPO = "gg-rac26ai-lab";
  var GH_BRANCH = "main";

  var host = window.location.hostname;
  var owner = /\.github\.io$/i.test(host) ? host.split(".")[0] : GH_OWNER;
  var base = "https://github.com/" + owner + "/" + GH_REPO;

  document.querySelectorAll("a[data-gh]").forEach(function (a) {
    var path = a.getAttribute("data-gh");
    a.href = path ? base + "/blob/" + GH_BRANCH + "/" + path : base;
    a.rel = "noopener";
  });

  // Keep the current section when switching EN <-> PL.
  document.querySelectorAll("a[data-lang-switch]").forEach(function (a) {
    a.addEventListener("click", function () {
      if (window.location.hash) { a.href = a.getAttribute("href").split("#")[0] + window.location.hash; }
    });
  });
})();
