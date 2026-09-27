/*
 * URL & endpoint scraper bookmarklet.
 *
 * Pulls URLs and path-like strings out of the current page — from anchor/
 * script/img/link/form tags, inline HTML, quoted strings in scripts, and the
 * Performance resource timing entries — then renders them in an overlay.
 *
 * How to use:
 *   1. Create a new browser bookmark.
 *   2. Paste the single-line "javascript:" version below (see BOOKMARKLET)
 *      as the bookmark's URL/location.
 *   3. Click it on any page to list discovered URLs & endpoints.
 *
 * The readable source is kept here for maintenance; the minified line at the
 * bottom is what actually goes in the bookmark.
 */

(function () {
  var box = document.createElement("div");
  box.style.cssText =
    "position:fixed;bottom:0;left:0;width:100%;height:300px;background:#1a1a1a;" +
    "color:#0f0;z-index:999999;padding:20px;overflow:auto;font-family:monospace;";
  box.innerHTML =
    '<h3 style="color:#0f0;margin:0 0 10px">URL & Endpoint Scraper</h3>' +
    '<div id="_us_results">Scanning...</div>';
  document.body.appendChild(box);

  var host = window.location.hostname;

  function collect() {
    var urls = [];
    var tags = [].concat(
      [].slice.call(document.getElementsByTagName("a")),
      [].slice.call(document.getElementsByTagName("script")),
      [].slice.call(document.getElementsByTagName("img")),
      [].slice.call(document.getElementsByTagName("link")),
      [].slice.call(document.getElementsByTagName("form"))
    );
    tags.forEach(function (el) {
      if (el.href) urls.push(el.href);
      if (el.src) urls.push(el.src);
      if (el.action) urls.push(el.action);
    });

    var html = document.documentElement.innerHTML;
    var attrRe =
      /(?:url\(|href="|src="|action="|url:|endpoint:|path:|route:)\s*['"]?([^'")\s>]+)/gi;
    var m;
    while ((m = attrRe.exec(html)) !== null) {
      if (m[1] && m[1].indexOf("data:") !== 0) urls.push(m[1]);
    }

    var quoted = html.match(/"[^"]*"|'[^']*'/g) || [];
    quoted.forEach(function (s) {
      var paths = s.match(/(?:\/[a-zA-Z0-9_-]+)+(?:\.[a-zA-Z0-9]+)?/g) || [];
      paths.forEach(function (p) {
        urls.push(p);
      });
    });

    performance.getEntriesByType("resource").forEach(function (e) {
      urls.push(e.name);
    });

    return Array.prototype.slice.call(new Set(urls)).sort();
  }

  var found = collect();
  document.getElementById("_us_results").innerHTML =
    '<div style="color:#0f0;margin:10px 0">Found ' +
    found.length +
    " URLs & endpoints on " +
    host +
    '</div><div style="background:#2a2a2a;padding:10px;border-radius:5px">' +
    found
      .map(function (u) {
        return (
          '<div style="color:#fff;margin:5px 0;padding:5px;background:#333;' +
          'border-radius:3px;word-break:break-all">' +
          u +
          "</div>"
        );
      })
      .join("") +
    "</div>";
})();

/*
BOOKMARKLET (paste this whole line as the bookmark URL):

javascript:(function(){var b=document.createElement('div');b.style.cssText='position:fixed;bottom:0;left:0;width:100%;height:300px;background:#1a1a1a;color:#0f0;z-index:999999;padding:20px;overflow:auto;font-family:monospace;';b.innerHTML='<h3 style="color:#0f0;margin:0 0 10px">URL & Endpoint Scraper</h3><div id="_us_results">Scanning...</div>';document.body.appendChild(b);var h=window.location.hostname;function c(){var u=[],t=[].concat([].slice.call(document.getElementsByTagName('a')),[].slice.call(document.getElementsByTagName('script')),[].slice.call(document.getElementsByTagName('img')),[].slice.call(document.getElementsByTagName('link')),[].slice.call(document.getElementsByTagName('form')));t.forEach(function(e){if(e.href)u.push(e.href);if(e.src)u.push(e.src);if(e.action)u.push(e.action);});var m,H=document.documentElement.innerHTML,r=/(?:url\(|href="|src="|action="|url:|endpoint:|path:|route:)\s*['"]?([^'")\s>]+)/gi;while((m=r.exec(H))!==null){if(m[1]&&m[1].indexOf('data:')!==0)u.push(m[1]);}(H.match(/"[^"]*"|'[^']*'/g)||[]).forEach(function(s){(s.match(/(?:\/[a-zA-Z0-9_-]+)+(?:\.[a-zA-Z0-9]+)?/g)||[]).forEach(function(p){u.push(p);});});performance.getEntriesByType('resource').forEach(function(e){u.push(e.name);});return Array.prototype.slice.call(new Set(u)).sort();}var f=c();document.getElementById('_us_results').innerHTML='<div style="color:#0f0;margin:10px 0">Found '+f.length+' URLs & endpoints on '+h+'</div><div style="background:#2a2a2a;padding:10px;border-radius:5px">'+f.map(function(x){return '<div style="color:#fff;margin:5px 0;padding:5px;background:#333;border-radius:3px;word-break:break-all">'+x+'</div>';}).join('')+'</div>';})();
*/
