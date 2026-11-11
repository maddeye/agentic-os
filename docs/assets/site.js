// Agent OS documentation: theme switch, search, copy buttons, outline highlight.
(function () {
	"use strict";
	var root = document.documentElement;

	// Theme. The inline script in <head> already applied the stored choice.
	document.querySelector(".theme").addEventListener("click", function () {
		var next = root.dataset.theme === "light" ? "dark" : "light";
		root.dataset.theme = next;
		try { localStorage.setItem("aos-theme", next); } catch (e) {}
	});

	// Sidebar on narrow screens.
	document.querySelector(".menu").addEventListener("click", function () {
		document.body.classList.toggle("nav-open");
	});

	// Copy buttons.
	document.querySelectorAll(".code button").forEach(function (button) {
		button.addEventListener("click", function () {
			var text = button.closest(".code").querySelector("pre").textContent;
			navigator.clipboard.writeText(text).then(function () {
				button.textContent = "Copied";
				setTimeout(function () { button.textContent = "Copy"; }, 1500);
			});
		});
	});

	// Outline: mark the section that is being read.
	var links = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
	var heads = links.map(function (a) { return document.getElementById(decodeURIComponent(a.hash.slice(1))); });
	function spy() {
		var current = 0;
		heads.forEach(function (h, i) { if (h && h.getBoundingClientRect().top < 120) current = i; });
		links.forEach(function (a, i) { a.classList.toggle("here", i === current); });
	}
	if (links.length) {
		addEventListener("scroll", spy, { passive: true });
		spy();
	}

	// Search. The index loads on first use.
	var input = document.querySelector(".search input");
	var list = document.querySelector(".results");
	var base = document.currentScript.src.replace(/site\.js.*$/, "");
	var index = null, loading = false, selected = -1;

	function load(done) {
		if (index) return done();
		if (loading) return;
		loading = true;
		var s = document.createElement("script");
		s.src = base + "search-index.js";
		s.onload = function () { index = window.AOS_SEARCH || []; done(); };
		document.head.appendChild(s);
	}
	function esc(s) {
		return s.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; });
	}
	function render() {
		var words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
		selected = -1;
		if (!words.length) { list.classList.remove("open"); return; }
		var hits = [];
		index.forEach(function (e) {
			var head = e.h.toLowerCase(), body = e.x.toLowerCase(), score = 0;
			for (var i = 0; i < words.length; i++) {
				if (head.indexOf(words[i]) >= 0) score += 10;
				else if (body.indexOf(words[i]) >= 0) score += 1;
				else return;
			}
			hits.push({ e: e, score: score });
		});
		hits.sort(function (a, b) { return b.score - a.score; });
		list.innerHTML = hits.slice(0, 12).map(function (hit) {
			var e = hit.e, at = e.x.toLowerCase().indexOf(words[0]);
			var from = Math.max(0, at - 40);
			var snippet = (from ? "…" : "") + e.x.slice(from, from + 110);
			return '<li><a href="' + base + "../" + e.u + '"><b>' + esc(e.h) + "</b><small>" + esc(e.p) + " · " + esc(snippet) + "</small></a></li>";
		}).join("") || '<li class="none">No results</li>';
		list.classList.add("open");
	}
	input.addEventListener("focus", function () { load(render); });
	input.addEventListener("input", function () { load(render); });
	input.addEventListener("keydown", function (ev) {
		var items = list.querySelectorAll("a");
		if (ev.key === "Escape") { input.blur(); list.classList.remove("open"); return; }
		if (ev.key === "Enter" && items.length) { location.href = items[Math.max(selected, 0)].href; return; }
		if (ev.key !== "ArrowDown" && ev.key !== "ArrowUp") return;
		ev.preventDefault();
		if (!items.length) return;
		selected = (selected + (ev.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
		items.forEach(function (a, i) { a.classList.toggle("sel", i === selected); });
		items[selected].scrollIntoView({ block: "nearest" });
	});
	document.addEventListener("click", function (ev) {
		if (!ev.target.closest(".search")) list.classList.remove("open");
	});
	document.addEventListener("keydown", function (ev) {
		if (ev.key === "/" && document.activeElement !== input) { ev.preventDefault(); input.focus(); }
	});
})();
