// Playoff-odds-over-time charts for Predictions.Rmd. Data comes from
// window.NHL_ODDS (one entry per division) and window.NHL_ODDS_META.
(function () {
  var DAY = 864e5;

  function draw(el) {
    var d = window.NHL_ODDS[el.dataset.division];
    var meta = window.NHL_ODDS_META;
    var first = new Date(meta.first).getTime();
    var last = new Date(meta.last).getTime();
    var span = Math.max(last - first, 10 * DAY);
    var logoX = last + span * 0.025;    // logos just past the line ends
    var logoW = span * 0.045;

    var traces = d.teams.map(function (t) {
      return {
        x: t.x, y: t.y, type: "scatter", mode: "lines", name: t.name,
        line: { color: t.color, width: 3 },
        hovertemplate: t.name + ": %{y:.1%}<extra></extra>"
      };
    });
    var images = d.teams.map(function (t) {
      return {
        source: t.logo, xref: "x", yref: "y",
        x: new Date(logoX).toISOString().slice(0, 10), y: t.logo_y,
        sizex: logoW, sizey: 0.09, xanchor: "left", yanchor: "middle",
        sizing: "contain", layer: "above"
      };
    });
    var shapes = d.teams.map(function (t) {
      return {
        type: "line", xref: "x", yref: "y",
        x0: t.x[t.x.length - 1], y0: t.y[t.y.length - 1],
        x1: new Date(logoX).toISOString().slice(0, 10), y1: t.logo_y,
        line: { color: "#999", width: 1 }
      };
    });
    [0, 0.5, 1].forEach(function (y) {
      shapes.push({ type: "line", xref: "paper", x0: 0, x1: 1, yref: "y", y0: y, y1: y,
                    layer: "below", line: { color: "#ccc", width: 1 } });
    });

    var layout = {
      title: { text: "<b>" + el.dataset.division + " Division Playoff Odds</b>",
               font: { size: 24 }, x: 0.5, y: 0.97 },
      annotations: [
        { text: meta.subtitle, xref: "paper", yref: "paper", x: 0.5, y: 1.07,
          showarrow: false, font: { size: 13, color: "#666" } },
        { text: meta.caption, xref: "paper", yref: "paper", x: 1, y: -0.12,
          xanchor: "right", showarrow: false, font: { size: 11, color: "#666" } }
      ],
      font: { family: "Outfit, sans-serif", color: "#222" },
      paper_bgcolor: "floralwhite", plot_bgcolor: "floralwhite",
      margin: { l: 60, r: 20, t: 90, b: 70 },
      showlegend: false,
      hovermode: "x unified",
      hoverlabel: { font: { family: "Outfit, sans-serif" } },
      xaxis: { type: "date", tickformat: "%b %-d", showgrid: false,
               range: [new Date(first - span * 0.01).toISOString().slice(0, 10),
                       new Date(logoX + logoW * 1.3).toISOString().slice(0, 10)],
               fixedrange: true },
      yaxis: { tickformat: ".0%", range: [-0.06, 1.1], dtick: 0.25,
               gridcolor: "#e8e8e8", zeroline: false, title: { text: "Playoff odds" },
               fixedrange: true },
      images: images, shapes: shapes
    };
    Plotly.newPlot(el, traces, layout, { responsive: true, displayModeBar: false });
    el.dataset.drawn = "1";
  }

  function refresh() {
    document.querySelectorAll(".odds-chart").forEach(function (el) {
      if (el.offsetParent === null) return;          // hidden tab
      if (el.dataset.drawn) Plotly.Plots.resize(el); else draw(el);
    });
  }

  $(document).on("shown.bs.tab", refresh);
  $(refresh);
})();
