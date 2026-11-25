angular.module('beamng.apps')

/**
 * Race Lights (PRM): the start lights, the flags and the drag tree, in a box
 * of their own so a driver can put them where they are already looking.
 *
 * NO ANGULAR BINDINGS. The light arrives on RaceManagerLights (pushed by
 * lua/ge/extensions/raceManager/lights.lua only when it changes) and is drawn
 * by setting classes on the SVG directly. Nothing here is watched, so the app
 * adds nothing to the digest the main panel already runs and never starts one.
 */
.directive('raceManagerLights', [function () {
  return {
    templateUrl: '/ui/modules/apps/RaceManagerLights/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$element', function ($scope, $element) {
      var root = $element[0];

      // Five lamps for a race. '-' is unlit; the letters are the color
      // classes in app.html. GET READY KEEPS THE LAMPS OF THE YELLOW IT ENDS and
      // changes only the words: blinking amber there was taken for the green,
      // and drivers jumped the start. The green is the first thing that moves.
      var RACE = {
        idle:        { lamps: '-----', cap: 'RACE LIGHTS' },
        grid:        { lamps: '-----', cap: 'ON THE GRID' },
        count3:      { lamps: 'r---r', cap: '3' },
        count2:      { lamps: 'rr-rr', cap: '2' },
        count1:      { lamps: 'rrrrr', cap: '1' },
        go:          { lamps: 'ggggg', cap: 'GO' },
        pace:        { lamps: 'y-y-y', cap: 'PACE LAP' },
        ready:        { lamps: 'y-y-y', cap: 'GET READY · HOLD' },
        readyRestart: { lamps: 'yy-yy', cap: 'GET READY · HOLD' },
        green:       { lamps: 'ggggg', cap: 'GREEN FLAG' },
        cautionBack: { lamps: 'yyyyy', cap: 'CAUTION · RACE BACK', blink: true },
        caution:     { lamps: 'yyyyy', cap: 'CAUTION' },
        restart:     { lamps: 'yy-yy', cap: 'RESTART THIS LAP' },
        yellow:      { lamps: '-yyy-', cap: 'YELLOW FLAG', blink: true },
        red:         { lamps: 'rrrrr', cap: 'RED FLAG' },
        white:       { lamps: 'wwwww', cap: 'LAST LAP' },
        checkered:   { lamps: 'ccccc', cap: 'CHECKERED FLAG' },
        blue:        { lamps: 'bbbbb', cap: 'BLUE FLAG', blink: true },
        // This driver's penalties. 'k' is a black lamp. The lift meter is
        // drawn by drawLift; its pattern here is only the fallback.
        lift:        { lamps: '-----', cap: 'LIFT OFF' },
        black:       { lamps: 'kkkkk', cap: 'BLACK FLAG · PIT' },
        liftServed:  { lamps: 'ggggg', cap: 'LIFT SERVED' },
        blackServed: { lamps: 'ggggg', cap: 'SERVED · GO' },
        dsq:         { lamps: 'kkkkk', cap: 'DISQUALIFIED' }
      };
      // THE LIFT METER IS GREEN ONLY. Red is the red flag and amber the drag
      // tree; a driver glancing at five red lamps mid-race would stop.
      var METER_LAMPS = 5;
      // A moment (GO, the green, a flag of your own) only shows over these. A
      // red or a caution that arrives during one wins at once. Over a penalty
      // of the driver's own too: the green ending a caution must not be lost to
      // a lift meter, which comes back when the moment is over.
      var LOW = { off: true, grid: true, lift: true, black: true };
      var HINT = ['a', 'a', 'a', 'g', 'r'];
      var PREVIEW_MS = 6000;
      // Widest a caption may run, per layout, before it is squeezed to fit.
      var CAP_MAX = { w: 470, t: 160 };
      // TALL WHEN THE BOX IS. HUD apps have no settings of their own, but the
      // driver sizes the box: drawn taller than it is wide, the lamps stand up.
      var TALL_RATIO = 1.25;
      var vertical = false;

      var standing = 'off';
      var tree = null;
      var lift = null;
      var black = null;
      var moment = null;
      var momentUntil = 0;
      var momentTimer = null;
      var slip = null;
      var preview = true;
      // What each element was last given, so a push that changes one lamp
      // writes one attribute.
      var written = {};
      var els = null;

      // BOTH LAYOUTS ARE KEPT CURRENT, the hidden one too, so switching shows
      // the right light at once. A write per lamp per change, a few times a race.
      function layout(svg, key) {
        return {
          key: key,
          race: svg ? svg.querySelectorAll('.rml-race .rml-lamp') : [],
          drag: svg ? svg.querySelectorAll('.rml-drag .rml-lamp') : [],
          pre: svg ? svg.querySelector('.rml-pre') : null,
          stage: svg ? svg.querySelector('.rml-stage') : null,
          cap: svg ? svg.querySelector('.rml-cap') : null
        };
      }

      function el() {
        if (els) { return els; }
        els = [layout(root.querySelector('svg.rml-wide'), 'w'),
               layout(root.querySelector('svg.rml-tall'), 't')];
        return els;
      }

      function setClass(node, key, cls) {
        if (!node || written[key] === cls) { return; }
        written[key] = cls;
        node.setAttribute('class', cls);
      }

      // Squeezed to fit only when too long; stretching a short word to the full
      // width would look like a different font. A hidden layout measures zero,
      // so it is fitted again when it is shown (orient).
      function fit(L) {
        var cap = L.cap;
        if (!cap) { return; }
        cap.removeAttribute('textLength');
        cap.removeAttribute('lengthAdjust');
        try {
          if (cap.getComputedTextLength() > CAP_MAX[L.key]) {
            cap.setAttribute('textLength', String(CAP_MAX[L.key]));
            cap.setAttribute('lengthAdjust', 'spacingAndGlyphs');
          }
        } catch (e) { /* not laid out yet: the caption is still readable */ }
      }

      function setCaption(text) {
        el().forEach(function (L) {
          if (!L.cap || written[L.key + 'cap'] === text) { return; }
          written[L.key + 'cap'] = text;
          L.cap.textContent = text;
          fit(L);
        });
      }

      function orient() {
        var w = root.clientWidth, h = root.clientHeight;
        if (!w || !h) { return; }
        var v = h > w * TALL_RATIO;
        if (v === vertical) { return; }
        vertical = v;
        root.classList.toggle('rml-vertical', v);
        fit(el()[v ? 1 : 0]);
      }

      // `lamps`: one letter per lamp, '-' unlit, 'm' an empty meter lamp, an
      // upper case letter that one lamp blinking. `rise`: the tall layout
      // reads bottom up, so a meter fills from the bottom there.
      function drawLamps(lamps, blinkAll, rise) {
        el().forEach(function (L) {
          var n = L.race.length;
          for (var i = 0; i < n; i++) {
            var c = lamps.charAt(rise && L.key === 't' ? n - 1 - i : i);
            var blink = blinkAll;
            if (c !== c.toLowerCase()) { c = c.toLowerCase(); blink = true; }
            var cls = 'rml-lamp';
            if (c === 'c') {
              cls += (i % 2 === 0) ? ' rml-chk-a' : ' rml-chk-b';
            } else if (c === 'm') {
              cls += ' rml-hint-w';
            } else if (c !== '-') {
              cls += ' rml-' + c + (blink ? ' rml-blink' : '');
            }
            setClass(L.race[i], L.key + 'r' + i, cls);
          }
        });
      }

      function drawRace(name) {
        var p = RACE[name] || RACE.idle;
        drawLamps(p.lamps, !!p.blink, false);
        var cap = p.cap;
        if (name === 'black' && black && black.by) { cap = 'BLACK FLAG · PIT BY LAP ' + black.by; }
        setCaption(cap);
      }

      function secs(v) {
        return Math.max(Number(v) || 0, 0).toFixed(1) + 's';
      }

      // Served lamps green, the one filling blinks, the rest an empty meter.
      function drawLift() {
        var t = lift || {};
        var full = Number(t.full) || 0;
        var left = Math.max(Number(t.left) || 0, 0);
        var done = full > 0 ? Math.min(Math.max(1 - left / full, 0), 1) : 0;
        var st = t.st || 'wait';
        var lit = st === 'restart' ? 0 : Math.floor(done * METER_LAMPS + 1e-6);
        var lamps = '';
        for (var i = 0; i < METER_LAMPS; i++) {
          if (i < lit) { lamps += 'g'; }
          else if (i === lit && st === 'lifting') { lamps += 'G'; }
          else { lamps += 'm'; }
        }
        drawLamps(lamps, false, true);
        var win = (t.win === null || t.win === undefined) ? '' : ' · ' + Math.ceil(Number(t.win)) + 's';
        var cap;
        if (st === 'restart') { cap = 'THROTTLE ON · ' + secs(left) + win; }
        else if (st === 'paused') { cap = 'LIFT PAUSED · ' + secs(left) + win; }
        else if (st === 'lifting') { cap = 'LIFT ' + secs(left) + win; }
        else { cap = 'LIFT OFF ' + secs(left) + win; }
        if (t.more > 0) { cap += ' · +' + t.more; }
        setCaption(cap);
      }

      function fmt(v, n) {
        return (v === null || v === undefined) ? '--' : Number(v).toFixed(n);
      }

      function drawTree() {
        var t = tree || {};
        var st = t.stage || 'off';
        var lit = [
          st === 'amber1' || st === 'amber2' || st === 'amber3',
          st === 'amber2' || st === 'amber3',
          st === 'amber3',
          st === 'green',
          st === 'red' || (!tree && slip && slip.foul)
        ];
        el().forEach(function (L) {
          for (var i = 0; i < L.drag.length; i++) {
            setClass(L.drag[i], L.key + 'd' + i,
              'rml-lamp ' + (lit[i] ? 'rml-' + HINT[i] : 'rml-hint-' + HINT[i]));
          }
          setClass(L.pre, L.key + 'pre', 'rml-small rml-pre' + (t.prestaged ? ' rml-on' : ''));
          setClass(L.stage, L.key + 'stage', 'rml-small rml-stage' + (t.staged ? ' rml-on' : ''));
        });
        if (!tree && slip) {
          setCaption((slip.foul ? 'RED  ' : '') + 'RT ' + fmt(slip.rt, 3)
            + '  ET ' + fmt(slip.et, 3) + '  ' + fmt(slip.speed, 1) + ' MPH');
        } else if (st === 'red') {
          setCaption('RED LIGHT');
        } else {
          var cap = t.lane ? 'LANE ' + t.lane : 'DRAG';
          if (t.dial) { cap += ' · DIAL ' + fmt(t.dial, 2); }
          if (t.delay > 0) { cap += ' · +' + fmt(t.delay, 3); }
          setCaption(cap);
        }
      }

      function render() {
        orient();
        var show = standing;
        if (moment && Date.now() < momentUntil) {
          if (LOW[show]) { show = moment; }
        } else {
          moment = null;
        }
        var dragMode = show === 'tree' || (show === 'off' && !!slip);
        root.classList.toggle('rml-dragmode', dragMode);
        if (dragMode) {
          drawTree();
        } else if (show === 'lift') {
          drawLift();
        } else {
          drawRace(show === 'off' ? 'idle' : show);
        }
        root.classList.toggle('rml-hidden', show === 'off' && !slip && !preview);
      }

      $scope.$on('RaceManagerLights', function (event, data) {
        if (!data) { return; }
        standing = data.light || 'off';
        tree = data.tree || null;
        lift = data.lift || null;
        black = data.black || null;
        if (data.moment) {
          moment = data.moment;
          momentUntil = Date.now() + (Number(data.hold) || 3) * 1000;
          if (momentTimer) { clearTimeout(momentTimer); }
          momentTimer = setTimeout(function () { momentTimer = null; render(); },
            momentUntil - Date.now() + 20);
        }
        // The resend answering this app's own load is usually 'off', and must
        // not cut the preview short.
        if (standing !== 'off' || data.moment) { preview = false; }
        render();
      });

      // This driver's time slip, held until drag.lua takes it down.
      $scope.$on('RaceManagerDragRun', function (event, data) {
        if (!data || data.clear || data.aborted) {
          slip = null;
        } else if (data.et != null || data.rt != null) {
          slip = { rt: data.rt, et: data.et, speed: data.speed, foul: data.foul === true };
        }
        render();
      });

      // SHOWN FOR A FEW SECONDS WHEN IT LOADS, so a driver who has just added
      // it can see where it went. After that it is invisible until there is a
      // light to show.
      render();
      var previewTimer = setTimeout(function () { preview = false; render(); }, PREVIEW_MS);

      // Resizing the box in the HUD editor flips the layout as it happens.
      // Without ResizeObserver it still flips, on the next light.
      var resizeWatch = null;
      if (window.ResizeObserver) {
        resizeWatch = new ResizeObserver(function () { orient(); });
        resizeWatch.observe(root);
      }

      // The light it missed while it was not loaded.
      if (window.bngApi) {
        bngApi.engineLua('if raceManager and raceManager.lightsResend then raceManager.lightsResend() end');
      }

      $scope.$on('$destroy', function () {
        if (momentTimer) { clearTimeout(momentTimer); }
        clearTimeout(previewTimer);
        if (resizeWatch) { resizeWatch.disconnect(); }
      });
    }]
  };
}]);
