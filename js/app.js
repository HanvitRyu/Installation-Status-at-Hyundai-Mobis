(function () {
  "use strict";

  var supabase = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

  var params = new URLSearchParams(window.location.search);
  var token = params.get("token") || "";

  var state = {
    // isAdmin: 마스터. installerId/installerName: 설치업체로 접속. groupId/groupName: 담당업체(총괄)로 접속
    // (설치업체 토큰이면 installerId/groupId 둘 다 채워짐 — 자기 소속 그룹도 알 수 있게)
    identity: { isAdmin: false, installerId: null, installerName: null, groupId: null, groupName: null },
    sites: [],                 // [{id,name,installer_id,status,install_date,manager_name,note,updated_by,updated_at}]
    installBysite: {},         // site_id -> { A: row, B: row, C: row }
    unitsBysite: {},           // site_id -> { B: [{unit_no,location}], C: [{unit_no,location,ip,gateway,subnet_mask,host_ip}] }
    installersById: {},        // installer_id -> { name, group_id, group_name }
    installersList: [],        // [{id,name,group_id,group_name}]
    groupsList: [],            // [{id,name}] (installersList에서 유도)
    activeSiteId: null,
    activeEditable: false,
    installDateSort: null, // null | "asc" | "desc"
    cRemoval: null // null | { target: number, units: [{location,ip,...}, ...] } — 모뎀(C) 실제수량이
                   // 예정수량보다 적을 때, 어떤 항목을 지울지 고르는 동안의 임시 상태
  };

  var PRODUCTS = ["A", "B", "C"];
  var PRODUCT_INFO = {
    A: { label: "GST-502" },
    B: { label: "GX-8200" },
    C: { label: "GX-8200 TCP/IP" }
  };

  // 수량별 반복 입력 필드 정의. B는 위치만, C는 위치+네트워크 정보.
  var UNIT_FIELDS = {
    B: [{ key: "location", label: "설치위치" }],
    C: [
      { key: "location", label: "설치위치" },
      { key: "ip", label: "IP" },
      { key: "mac_address", label: "MAC주소", placeholder: "AA:BB:CC:DD:EE:FF" },
      { key: "gateway", label: "게이트웨이" },
      { key: "subnet_mask", label: "서브넷마스크" },
      { key: "host_ip", label: "호스트IP" }
    ]
  };

  // MAC주소는 입력값을 "AA:BB:CC:DD:EE:FF" 형태로 자동 정리해준다.
  function formatMacAddress(raw) {
    var hex = raw.replace(/[^0-9a-fA-F]/g, "").toUpperCase().slice(0, 12);
    var groups = hex.match(/.{1,2}/g);
    return groups ? groups.join(":") : hex;
  }

  // ---------- DOM refs ----------
  var el = {
    identityBadge: document.getElementById("identity-badge"),
    statTotal: document.getElementById("stat-total"),
    statDone: document.getElementById("stat-done"),
    statPercent: document.getElementById("stat-percent"),
    groupStats: document.getElementById("group-stats"),
    search: document.getElementById("search-input"),
    filterStatus: document.getElementById("filter-status"),
    filterGroup: document.getElementById("filter-group"),
    filterInstaller: document.getElementById("filter-installer"),
    sortInstallDateBtn: document.getElementById("sort-install-date"),
    exportBtn: document.getElementById("export-csv-btn"),
    tbody: document.getElementById("sites-tbody"),
    tfootCount: document.getElementById("tfoot-count"),
    tfootA: document.getElementById("tfoot-a"),
    tfootB: document.getElementById("tfoot-b"),
    tfootC: document.getElementById("tfoot-c"),
    modal: document.getElementById("detail-modal"),
    modalClose: document.getElementById("modal-close"),
    detailTitle: document.getElementById("detail-title"),
    siteInfo: document.getElementById("detail-site-info"),
    readonlyNotice: document.getElementById("detail-readonly-notice"),
    fGroup: document.getElementById("f-group"),
    fInstaller: document.getElementById("f-installer"),
    fStatus: document.getElementById("f-status"),
    fInstallDate: document.getElementById("f-install-date"),
    fNote: document.getElementById("f-note"),
    productTbody: document.getElementById("product-tbody"),
    bUnitsList: document.getElementById("b-units-list"),
    cUnitsList: document.getElementById("c-units-list"),
    cRemovalNotice: document.getElementById("c-removal-notice"),
    detailMeta: document.getElementById("detail-meta"),
    saveAllBtn: document.getElementById("save-all-btn"),
    saveAllMsg: document.getElementById("save-all-msg")
  };

  var UNIT_LISTS = { B: el.bUnitsList, C: el.cUnitsList };

  // ---------- helpers ----------
  function esc(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function statusBadgeClass(status) {
    return status === "완료" ? "st-done" : "st-none";
  }

  function canEditSite(site) {
    if (!token) return false;
    if (state.identity.isAdmin) return true;
    if (state.identity.installerId !== null && site.installer_id === state.identity.installerId) return true;
    if (state.identity.groupId !== null && getEffectiveGroupId(site) === state.identity.groupId) return true;
    return false;
  }

  // 설치업체가 배정되어 있으면 그 소속 담당업체가 기준, 없으면 사업장에 직접 잠정 배정된 담당업체를 쓴다.
  function getEffectiveGroupId(site) {
    var inst = state.installersById[site.installer_id];
    if (inst) return inst.group_id;
    return site.group_id || null;
  }

  function getEffectiveGroupName(site) {
    var gid = getEffectiveGroupId(site);
    if (gid == null) return null;
    var g = state.groupsList.find(function (x) { return x.id === gid; });
    return g ? g.name : null;
  }

  function formatDateTime(iso) {
    if (!iso) return "-";
    var d = new Date(iso);
    return d.toLocaleString("ko-KR", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  }

  // ---------- load ----------
  // 조회는 전부 토큰 검증 RPC를 통해서만 이뤄진다 (get_sites/get_installations/get_installation_units).
  // 토큰이 없거나, 배정받은 설치업체/담당업체가 아니면 해당 사업장은 애초에 응답에 포함되지 않는다.
  async function loadAll() {
    var results = await Promise.all([
      supabase.rpc("get_sites", { p_token: token }),
      supabase.rpc("get_installations", { p_token: token }),
      supabase.rpc("get_installation_units", { p_token: token }),
      supabase.rpc("list_installers", { p_token: token }),
      supabase.rpc("identify", { p_token: token })
    ]);

    var sitesRes = results[0], instRes = results[1], unitsRes = results[2], installersRes = results[3], identifyRes = results[4];

    if (sitesRes.error) throw sitesRes.error;
    if (instRes.error) throw instRes.error;
    if (unitsRes.error) throw unitsRes.error;
    if (installersRes.error) throw installersRes.error;
    if (identifyRes.error) throw identifyRes.error;

    state.sites = (sitesRes.data || []).slice().sort(function (a, b) { return a.id - b.id; });

    state.installBysite = {};
    (instRes.data || []).forEach(function (row) {
      if (!state.installBysite[row.site_id]) state.installBysite[row.site_id] = {};
      state.installBysite[row.site_id][row.product] = row;
    });

    state.unitsBysite = {};
    (unitsRes.data || []).forEach(function (row) {
      if (!state.unitsBysite[row.site_id]) state.unitsBysite[row.site_id] = { B: [], C: [] };
      state.unitsBysite[row.site_id][row.product].push(row);
    });

    state.installersList = installersRes.data || [];
    state.installersById = {};
    state.installersList.forEach(function (i) {
      state.installersById[i.id] = { name: i.name, group_id: i.group_id, group_name: i.group_name };
    });
    var groupMap = {};
    state.installersList.forEach(function (i) { groupMap[i.group_id] = i.group_name; });
    state.groupsList = Object.keys(groupMap).map(function (id) { return { id: parseInt(id, 10), name: groupMap[id] }; })
      .sort(function (a, b) { return a.id - b.id; });

    var idRow = (identifyRes.data && identifyRes.data[0]) || { is_admin: false, installer_id: null, installer_name: null, group_id: null, group_name: null };
    state.identity = {
      isAdmin: !!idRow.is_admin,
      installerId: idRow.installer_id,
      installerName: idRow.installer_name,
      groupId: idRow.group_id,
      groupName: idRow.group_name
    };
  }

  // ---------- render: identity + filters + stats ----------
  function renderIdentity() {
    var badge = el.identityBadge;
    if (state.identity.isAdmin) {
      badge.textContent = "마스터 관리자로 접속 중";
      badge.className = "identity-badge is-admin";
    } else if (state.identity.installerId) {
      badge.textContent = state.identity.installerName + " (" + state.identity.groupName + " 소속) 설치업체로 접속 중";
      badge.className = "identity-badge is-contractor";
    } else if (state.identity.groupId) {
      badge.textContent = state.identity.groupName + " 담당업체(총괄)로 접속 중";
      badge.className = "identity-badge is-contractor";
    } else {
      badge.textContent = "접속 권한 없음 (유효한 링크로 접속해주세요)";
      badge.className = "identity-badge";
    }
    el.exportBtn.classList.toggle("hidden", !state.identity.isAdmin);
  }

  function renderFilterOptions() {
    var groupSel = el.filterGroup;
    groupSel.innerHTML = '<option value="">전체 담당업체</option>';
    state.groupsList.forEach(function (g) {
      var opt = document.createElement("option");
      opt.value = g.id;
      opt.textContent = g.name;
      groupSel.appendChild(opt);
    });

    var instSel = el.filterInstaller;
    instSel.innerHTML = '<option value="">전체 설치업체</option>';
    state.installersList.forEach(function (i) {
      var opt = document.createElement("option");
      opt.value = i.id;
      opt.textContent = i.name;
      instSel.appendChild(opt);
    });
  }

  // 상단 전체 통계는 검색/필터 선택과 무관하게 항상 전체 사업장(59개) 기준으로 고정한다.
  function renderStats() {
    var list = state.sites;
    var total = list.length;
    var done = list.filter(function (s) { return s.status === "완료"; }).length;
    var pct = total ? Math.round((done / total) * 100) : 0;
    el.statTotal.textContent = total;
    el.statDone.textContent = done;
    el.statPercent.textContent = pct + "%";
  }

  // 담당업체별 미니 통계도 검색/필터 선택과 무관하게 항상 전체 사업장 기준으로 고정한다.
  function renderGroupStats() {
    var list = state.sites;
    var byGroup = {};
    list.forEach(function (s) {
      var gid = getEffectiveGroupId(s);
      if (gid == null) return; // 담당업체도 안 정해진 사업장은 그룹 통계에서 제외
      if (!byGroup[gid]) byGroup[gid] = { total: 0, done: 0 };
      byGroup[gid].total++;
      if (s.status === "완료") byGroup[gid].done++;
    });

    el.groupStats.innerHTML = state.groupsList.map(function (g) {
      var stat = byGroup[g.id] || { total: 0, done: 0 };
      var pct = stat.total ? Math.round((stat.done / stat.total) * 100) : 0;
      return (
        '<div class="group-stat-card">' +
        '<div class="group-stat-name">' + esc(g.name) + "</div>" +
        '<div class="group-stat-metrics">' +
        '<div><strong>' + stat.total + '</strong><span>담당 사업장</span></div>' +
        '<div><strong>' + stat.done + '</strong><span>완료</span></div>' +
        '<div class="accent"><strong>' + pct + '%</strong><span>완료율</span></div>' +
        '<button class="calendar-btn" data-group-id="' + g.id + '" title="설치 일정 보기">📅 설치일정</button>' +
        "</div></div>"
      );
    }).join("");
  }

  // ---------- 담당업체별 설치 일정 달력 (새 창) ----------
  function buildScheduleHtml(groupName, events) {
    var eventsJson = JSON.stringify(events).replace(/</g, "\\u003c");
    return "<!doctype html>" +
      '<html lang="ko"><head><meta charset="UTF-8">' +
      "<title>" + esc(groupName) + " 설치 일정</title>" +
      "<style>" +
      ":root{--surface-1:#fcfcfb;--page-plane:#f9f9f7;--text-primary:#0b0b0b;--text-secondary:#52514e;" +
      "--text-muted:#898781;--gridline:#e1e0d9;--accent:#2a78d6;--status-good:#0ca30c;}" +
      "*{box-sizing:border-box;}" +
      'body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--page-plane);color:var(--text-primary);}' +
      "header{padding:16px 20px;background:var(--surface-1);border-bottom:1px solid var(--gridline);}" +
      "header h1{font-size:16px;margin:0;}" +
      ".nav{display:flex;align-items:center;gap:12px;padding:14px 20px;}" +
      ".nav button{border:1px solid var(--gridline);background:var(--surface-1);border-radius:6px;padding:6px 12px;cursor:pointer;font-size:14px;}" +
      ".nav .label{font-size:15px;font-weight:600;min-width:110px;text-align:center;}" +
      ".grid{display:grid;grid-template-columns:repeat(7,1fr);gap:1px;background:var(--gridline);margin:0 20px 20px;border:1px solid var(--gridline);}" +
      ".dow{background:var(--surface-1);text-align:center;font-size:12px;color:var(--text-muted);padding:6px 0;}" +
      ".cell{background:var(--surface-1);min-height:88px;padding:6px;font-size:12px;}" +
      ".cell .daynum{color:var(--text-muted);margin-bottom:4px;}" +
      ".cell.today .daynum{color:var(--accent);font-weight:700;}" +
      ".cell.empty{background:var(--page-plane);}" +
      ".chip{display:block;font-size:11px;padding:2px 5px;border-radius:5px;margin-bottom:2px;background:rgba(137,135,129,0.14);color:var(--text-secondary);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}" +
      ".chip.done{background:rgba(12,163,12,0.14);color:var(--status-good);}" +
      "</style></head><body>" +
      "<header><h1>" + esc(groupName) + " 설치 일정</h1></header>" +
      '<div class="nav"><button id="prev">◀</button><div class="label" id="label"></div><button id="next">▶</button></div>' +
      '<div class="grid" id="grid"></div>' +
      "<script>" +
      "var EVENTS = " + eventsJson + ";" +
      "var byDate = {};" +
      "EVENTS.forEach(function(e){ if(!byDate[e.date]) byDate[e.date]=[]; byDate[e.date].push(e); });" +
      "function pickInitialMonth(){" +
      "  if (EVENTS.length === 0) return new Date();" +
      "  var sorted = EVENTS.slice().sort(function(a,b){ return a.date < b.date ? -1 : 1; });" +
      "  var todayStr = new Date().toISOString().slice(0,10);" +
      "  var upcoming = sorted.find(function(e){ return e.date >= todayStr; });" +
      '  return new Date((upcoming || sorted[0]).date + "T00:00:00");' +
      "}" +
      "var cur = pickInitialMonth();" +
      "function render(){" +
      "  var y = cur.getFullYear(), m = cur.getMonth();" +
      '  document.getElementById("label").textContent = y + "년 " + (m+1) + "월";' +
      '  var grid = document.getElementById("grid");' +
      '  grid.innerHTML = "";' +
      '  ["일","월","화","수","목","금","토"].forEach(function(d){' +
      '    var el = document.createElement("div"); el.className = "dow"; el.textContent = d; grid.appendChild(el);' +
      "  });" +
      "  var firstDay = new Date(y, m, 1);" +
      "  var startOffset = firstDay.getDay();" +
      "  var daysInMonth = new Date(y, m+1, 0).getDate();" +
      '  var todayStr = new Date().toISOString().slice(0,10);' +
      "  for (var i=0; i<startOffset; i++){" +
      '    var e = document.createElement("div"); e.className = "cell empty"; grid.appendChild(e);' +
      "  }" +
      "  for (var d=1; d<=daysInMonth; d++){" +
      '    var dateStr = y + "-" + String(m+1).padStart(2,"0") + "-" + String(d).padStart(2,"0");' +
      '    var cell = document.createElement("div");' +
      '    cell.className = "cell" + (dateStr === todayStr ? " today" : "");' +
      '    var num = document.createElement("div"); num.className = "daynum"; num.textContent = d;' +
      "    cell.appendChild(num);" +
      "    (byDate[dateStr] || []).forEach(function(ev){" +
      '      var chip = document.createElement("div");' +
      '      chip.className = "chip" + (ev.status === "완료" ? " done" : "");' +
      "      chip.textContent = ev.name;" +
      "      cell.appendChild(chip);" +
      "    });" +
      "    grid.appendChild(cell);" +
      "  }" +
      "}" +
      'document.getElementById("prev").addEventListener("click", function(){ cur = new Date(cur.getFullYear(), cur.getMonth()-1, 1); render(); });' +
      'document.getElementById("next").addEventListener("click", function(){ cur = new Date(cur.getFullYear(), cur.getMonth()+1, 1); render(); });' +
      "render();" +
      "<\/script></body></html>";
  }

  function openScheduleWindow(groupId, groupName) {
    var events = state.sites
      .filter(function (s) {
        var inst = state.installersById[s.installer_id];
        return inst && inst.group_id === groupId && s.install_date;
      })
      .map(function (s) {
        return { name: s.name, date: s.install_date, status: s.status };
      });

    var win = window.open("", "_blank", "width=720,height=780");
    if (!win) {
      alert("팝업이 차단되었습니다. 브라우저의 팝업 차단을 해제한 뒤 다시 시도해주세요.");
      return;
    }
    win.document.write(buildScheduleHtml(groupName, events));
    win.document.close();
  }

  // ---------- render: table ----------
  function qtyCellHtml(inst) {
    if (!inst) return '<span class="qty-cell">- / -</span>';
    var planned = inst.planned_qty != null ? inst.planned_qty : 0;
    var actual = inst.actual_qty;
    var cls = "qty-cell";
    if (actual !== null && actual !== undefined) {
      cls += actual >= planned ? " met" : " under";
    }
    return '<span class="' + cls + '">' + planned + '<span class="sep">/</span><span class="actual">' + (actual === null || actual === undefined ? "-" : actual) + '</span></span>';
  }

  function updateSortButton() {
    var btn = el.sortInstallDateBtn;
    if (state.installDateSort === "asc") {
      btn.textContent = "▲"; btn.title = "설치일 빠른순 정렬 중 (클릭 시 늦은순)"; btn.classList.add("active");
    } else if (state.installDateSort === "desc") {
      btn.textContent = "▼"; btn.title = "설치일 늦은순 정렬 중 (클릭 시 빠른순)"; btn.classList.add("active");
    } else {
      btn.textContent = "↕"; btn.title = "설치일 빠른순 정렬"; btn.classList.remove("active");
    }
  }

  function getFilteredSites() {
    var q = el.search.value.trim().toLowerCase();
    var statusFilter = el.filterStatus.value;
    var groupFilter = el.filterGroup.value;
    var installerFilter = el.filterInstaller.value;

    var list = state.sites.filter(function (s) {
      if (statusFilter && s.status !== statusFilter) return false;
      var inst = state.installersById[s.installer_id];
      var effGroupId = getEffectiveGroupId(s);
      if (installerFilter && String(s.installer_id) !== installerFilter) return false;
      if (groupFilter && String(effGroupId) !== groupFilter) return false;
      if (q) {
        var haystack = (s.name + " " + (inst ? inst.name : "") + " " + (getEffectiveGroupName(s) || "")).toLowerCase();
        if (haystack.indexOf(q) === -1) return false;
      }
      return true;
    });

    if (state.installDateSort) {
      var dir = state.installDateSort === "asc" ? 1 : -1;
      list = list.slice().sort(function (a, b) {
        if (!a.install_date && !b.install_date) return 0;
        if (!a.install_date) return 1;  // 설치일 없는 사업장은 항상 맨 뒤로
        if (!b.install_date) return -1;
        return a.install_date < b.install_date ? -dir : a.install_date > b.install_date ? dir : 0;
      });
    }

    return list;
  }

  function renderTable() {
    var filtered = getFilteredSites();
    renderStats();
    renderGroupStats();
    renderQuantityTotals(filtered);

    if (!filtered.length) {
      var msg = state.sites.length
        ? "조건에 맞는 사업장이 없습니다."
        : "조회 가능한 사업장이 없습니다. 설치업체/담당업체/마스터 링크(?token=...)로 접속해주세요.";
      el.tbody.innerHTML = '<tr class="empty-row"><td colspan="10">' + msg + "</td></tr>";
      return;
    }

    var html = filtered.map(function (s, i) {
      var inst = state.installBysite[s.id] || {};
      var installer = state.installersById[s.installer_id];
      return (
        '<tr data-site-id="' + s.id + '">' +
        "<td>" + (i + 1) + "</td>" +
        "<td>" + esc(getEffectiveGroupName(s) || "미배정") + "</td>" +
        "<td>" + esc(s.name) + "</td>" +
        "<td>" + esc(installer ? installer.name : "미배정") + "</td>" +
        '<td><span class="status-badge ' + statusBadgeClass(s.status) + '">' + esc(s.status || "미착수") + "</span></td>" +
        "<td>" + qtyCellHtml(inst.A) + "</td>" +
        "<td>" + qtyCellHtml(inst.B) + "</td>" +
        "<td>" + qtyCellHtml(inst.C) + "</td>" +
        "<td>" + esc(s.install_date || "-") + "</td>" +
        "<td>" + esc(s.updated_by ? s.updated_by + " · " + formatDateTime(s.updated_at) : "-") + "</td>" +
        "</tr>"
      );
    }).join("");

    el.tbody.innerHTML = html;
  }

  // 표에 현재 조회(필터링)된 사업장 기준 품목별 예정/실제 수량 합계 — 정렬 상태와 무관하게 항상 정확함
  function renderQuantityTotals(filtered) {
    var list = filtered || state.sites;
    var sums = {
      A: { planned_qty: 0, actual_qty: 0 },
      B: { planned_qty: 0, actual_qty: 0 },
      C: { planned_qty: 0, actual_qty: 0 }
    };
    list.forEach(function (s) {
      var inst = state.installBysite[s.id] || {};
      PRODUCTS.forEach(function (p) {
        var row = inst[p];
        if (!row) return;
        sums[p].planned_qty += row.planned_qty || 0;
        if (row.actual_qty != null) sums[p].actual_qty += row.actual_qty;
      });
    });
    el.tfootCount.textContent = list.length;
    el.tfootA.innerHTML = qtyCellHtml(sums.A);
    el.tfootB.innerHTML = qtyCellHtml(sums.B);
    el.tfootC.innerHTML = qtyCellHtml(sums.C);
  }

  // ---------- units (product B: 위치만 / product C: 위치+네트워크 정보), 실제수량만큼 반복 ----------
  function getUnitFieldsFromDom(product) {
    var container = UNIT_LISTS[product];
    var fields = UNIT_FIELDS[product];
    var map = {};
    container.querySelectorAll(".network-unit-group").forEach(function (g) {
      var n = parseInt(g.getAttribute("data-unit-no"), 10);
      var vals = {};
      fields.forEach(function (f) {
        vals[f.key] = g.querySelector('[data-field="' + f.key + '"]').value;
      });
      map[n] = vals;
    });
    return map;
  }

  // 필드가 여러 개인 품목(C)의 카드 하나를 만든다. removable=true면 값 입력은 잠기고
  // 대신 "삭제" 체크박스가 붙는다 (실제수량이 예정수량보다 적을 때 고르는 용도).
  function buildUnitGroupHtml(product, n, values, editable, removable) {
    var fields = UNIT_FIELDS[product];
    var fieldsHtml = fields.map(function (f) {
      var v = values[f.key] || "";
      return '<label>' + esc(f.label) + '<input type="text" data-field="' + f.key + '" placeholder="' + esc(f.placeholder || "") + '" value="' + esc(v) + '" ' + (editable && !removable ? "" : "disabled") + "></label>";
    }).join("");
    var removeToggle = removable
      ? '<label class="unit-remove-toggle"><input type="checkbox" class="unit-remove-checkbox" data-idx="' + (n - 1) + '"><span class="unit-remove-x">✕</span> 삭제</label>'
      : "";
    return (
      '<div class="network-unit-group' + (removable ? " removal" : "") + '" data-unit-no="' + n + '">' +
      '<div class="unit-label">' + esc(PRODUCT_INFO[product].label) + " " + n + "번째" + removeToggle + "</div>" +
      '<div class="unit-fields">' + fieldsHtml + "</div></div>"
    );
  }

  function renderUnits(product, siteId, count, editable) {
    var container = UNIT_LISTS[product];
    var fields = UNIT_FIELDS[product];
    var domValues = getUnitFieldsFromDom(product);
    var stateValues = {};
    ((state.unitsBysite[siteId] || {})[product] || []).forEach(function (u) { stateValues[u.unit_no] = u; });

    count = Math.max(0, parseInt(count, 10) || 0);
    if (count === 0) {
      container.innerHTML = '<p class="network-units-empty">' + esc(PRODUCT_INFO[product].label) + ' 실제수량을 입력하면 그 대수만큼 입력란이 생성됩니다.</p>';
      return;
    }

    var compact = fields.length === 1; // 필드가 위치 하나뿐인 품목(B)은 칸을 작게 모아서 표시
    var html = "";
    for (var n = 1; n <= count; n++) {
      var dom = domValues[n] || {};
      var st = stateValues[n] || {};
      if (compact) {
        var onlyField = fields[0];
        var onlyValue = dom[onlyField.key] !== undefined ? dom[onlyField.key] : (st[onlyField.key] || "");
        html +=
          '<div class="network-unit-group compact" data-unit-no="' + n + '">' +
          '<span class="unit-no">' + n + '</span>' +
          '<input type="text" data-field="' + onlyField.key + '" placeholder="' + esc(onlyField.label) + '" value="' + esc(onlyValue) + '" ' + (editable ? "" : "disabled") + ">" +
          "</div>";
      } else {
        var merged = {};
        fields.forEach(function (f) { merged[f.key] = dom[f.key] !== undefined ? dom[f.key] : (st[f.key] || ""); });
        html += buildUnitGroupHtml(product, n, merged, editable, false);
      }
    }
    container.innerHTML = html;
  }

  // ---------- 모뎀(C) 전용: 실제수량이 예정수량보다 적을 때 삭제할 항목 선택 ----------
  function renderCRemovalUI() {
    var remaining = state.cRemoval.units.length - state.cRemoval.target;
    el.cRemovalNotice.textContent = "실제수량이 예정수량보다 적습니다. 삭제할 " + remaining + "개를 선택해주세요.";
    el.cRemovalNotice.classList.remove("hidden");
    el.saveAllBtn.disabled = true;
    el.cUnitsList.innerHTML = state.cRemoval.units.map(function (u, idx) {
      return buildUnitGroupHtml("C", idx + 1, u, false, true);
    }).join("");
  }

  function exitCRemovalMode() {
    var finalUnits = state.cRemoval ? state.cRemoval.units : [];
    var target = state.cRemoval ? state.cRemoval.target : finalUnits.length;
    state.cRemoval = null;
    el.cRemovalNotice.classList.add("hidden");
    el.saveAllBtn.disabled = false;
    el.cUnitsList.innerHTML = finalUnits.length
      ? finalUnits.map(function (u, idx) { return buildUnitGroupHtml("C", idx + 1, u, state.activeEditable, false); }).join("")
      : '<p class="network-units-empty">GX-8200 TCP/IP 실제수량을 입력하면 그 대수만큼 입력란이 생성됩니다.</p>';
    // 삭제 도중 다시 수량을 늘려 정리 없이 빠져나온 경우, 목표치만큼 칸을 마저 채워준다.
    if (target > finalUnits.length) {
      renderUnits("C", state.activeSiteId, target, state.activeEditable);
    }
  }

  // 모뎀(C) "실제수량" 입력을 다 마쳤을 때(포커스 아웃) 호출. 예정보다 적으면 삭제 선택 모드로 들어간다.
  function handleCActualQtyChange(rawValue) {
    var newVal = parseInt(rawValue, 10);
    if (isNaN(newVal) || newVal < 0) newVal = 0;

    if (state.cRemoval) {
      state.cRemoval.target = newVal;
      if (state.cRemoval.units.length <= newVal) exitCRemovalMode();
      else renderCRemovalUI();
      return;
    }

    var currentCount = el.cUnitsList.querySelectorAll(".network-unit-group").length;
    if (newVal >= currentCount) {
      renderUnits("C", state.activeSiteId, newVal, state.activeEditable);
      return;
    }

    var domValues = getUnitFieldsFromDom("C");
    var orderedValues = [];
    for (var n = 1; n <= currentCount; n++) orderedValues.push(domValues[n] || {});
    state.cRemoval = { target: newVal, units: orderedValues };
    renderCRemovalUI();
  }

  // 사업장 상세 상단의 참고용 정보(주소/현장담당자/모니터링 PC) — 읽기 전용, 값 없으면 줄 생략
  function renderSiteInfo(site) {
    var rows = [
      ["주소", site.address],
      ["현장 담당자", [site.site_contact_name, site.site_contact_phone].filter(Boolean).join(" · ")],
      ["담당자 이메일", site.site_contact_email],
      ["모니터링 PC", [site.monitor_location, site.monitor_pc_ip].filter(Boolean).join(" / ")]
    ].filter(function (r) { return r[1]; });
    el.siteInfo.innerHTML = rows.map(function (r) {
      return "<div><strong>" + esc(r[0]) + ":</strong> " + esc(r[1]) + "</div>";
    }).join("");
  }

  // ---------- detail modal ----------
  function openDetail(siteId) {
    var site = state.sites.find(function (s) { return s.id === siteId; });
    if (!site) return;
    state.activeSiteId = siteId;

    var editable = canEditSite(site);

    el.detailTitle.textContent = site.name;
    renderSiteInfo(site);
    el.readonlyNotice.classList.toggle("hidden", editable);

    el.fGroup.innerHTML = '<option value="">미배정</option>' + state.groupsList.map(function (g) {
      return '<option value="' + g.id + '">' + esc(g.name) + "</option>";
    }).join("");
    el.fGroup.value = getEffectiveGroupId(site) || "";
    // 설치업체가 이미 정해져 있으면 담당업체는 거기서 자동으로 정해지므로 직접 수정 불가.
    el.fGroup.disabled = !state.identity.isAdmin || !!site.installer_id;

    var optgroupsHtml = state.groupsList.map(function (g) {
      var opts = state.installersList.filter(function (i) { return i.group_id === g.id; }).map(function (i) {
        return '<option value="' + i.id + '">' + esc(i.name) + "</option>";
      }).join("");
      return '<optgroup label="' + esc(g.name) + '">' + opts + "</optgroup>";
    }).join("");
    el.fInstaller.innerHTML = '<option value="">미배정</option>' + optgroupsHtml;
    el.fInstaller.value = site.installer_id || "";
    el.fInstaller.disabled = !state.identity.isAdmin;

    el.fStatus.value = site.status || "미착수";
    el.fInstallDate.value = site.install_date || "";
    el.fNote.value = site.note || "";
    [el.fStatus, el.fInstallDate, el.fNote].forEach(function (f) { f.disabled = !editable; });
    el.saveAllBtn.classList.toggle("hidden", !editable);
    el.saveAllBtn.disabled = false; // 이전 사업장에서 삭제 선택 모드로 잠겼던 상태가 남아있지 않도록 초기화
    el.saveAllMsg.textContent = "";
    el.saveAllMsg.className = "save-msg";

    state.activeEditable = editable;

    var inst = state.installBysite[siteId] || {};
    el.productTbody.innerHTML = PRODUCTS.map(function (p) {
      var row = inst[p] || { planned_qty: 0, actual_qty: null };
      var info = PRODUCT_INFO[p];
      return (
        '<tr data-product="' + p + '">' +
        "<td><strong>" + esc(info.label) + "</strong></td>" +
        "<td>" + (row.planned_qty != null ? row.planned_qty : 0) + "</td>" +
        '<td><input type="number" class="f-actual-qty" min="0" value="' + (row.actual_qty ?? "") + '" ' + (editable ? "" : "disabled") + "></td>" +
        "</tr>"
      );
    }).join("");

    el.bUnitsList.innerHTML = ""; // clear previous site's fields so they aren't read back as stale DOM values
    el.cUnitsList.innerHTML = "";
    state.cRemoval = null;
    el.cRemovalNotice.classList.add("hidden");

    var bRow = inst.B;
    var bQty = bRow && bRow.actual_qty != null ? bRow.actual_qty : ((state.unitsBysite[siteId] || {}).B || []).length;
    renderUnits("B", siteId, bQty, editable);

    // 모뎀(C): 실제수량이 아직 없으면 예정수량만큼 미리 칸을 만들어둔다.
    // 이미 실제수량이 저장돼 있으면(=이전에 정리 완료된 상태) 그 수를 그대로 따른다.
    var cRow = inst.C;
    var cExisting = ((state.unitsBysite[siteId] || {}).C || []).length;
    var cQty = cRow && cRow.actual_qty != null ? cRow.actual_qty : (cRow ? cRow.planned_qty || 0 : 0);
    cQty = Math.max(cQty, cExisting);
    renderUnits("C", siteId, cQty, editable);

    el.detailMeta.textContent = site.updated_by
      ? "최종 수정: " + site.updated_by + " · " + formatDateTime(site.updated_at)
      : "아직 수정 기록이 없습니다.";

    el.modal.classList.remove("hidden");
    if (history.replaceState) history.replaceState(null, "", window.location.pathname + window.location.search + "#site-" + siteId);
  }

  function closeDetail() {
    el.modal.classList.add("hidden");
    state.activeSiteId = null;
    state.cRemoval = null;
    el.cRemovalNotice.classList.add("hidden");
    el.saveAllBtn.disabled = false;
    if (history.replaceState) history.replaceState(null, "", window.location.pathname + window.location.search);
  }

  function collectUnitsFromDom(product) {
    var container = UNIT_LISTS[product];
    var fields = UNIT_FIELDS[product];
    var units = [];
    container.querySelectorAll(".network-unit-group").forEach(function (g) {
      var unit = { unit_no: parseInt(g.getAttribute("data-unit-no"), 10) };
      fields.forEach(function (f) { unit[f.key] = g.querySelector('[data-field="' + f.key + '"]').value || null; });
      units.push(unit);
    });
    return units;
  }

  async function handleSaveAll() {
    var siteId = state.activeSiteId;
    var site = state.sites.find(function (s) { return s.id === siteId; });
    if (!site || !canEditSite(site)) return;

    el.saveAllBtn.disabled = true;
    el.saveAllMsg.textContent = "저장 중...";
    el.saveAllMsg.className = "save-msg";
    try {
      var siteRes = await supabase.rpc("save_site", {
        p_token: token,
        p_site_id: siteId,
        p_status: el.fStatus.value,
        p_install_date: el.fInstallDate.value || null,
        p_manager_name: site.manager_name || null,
        p_note: el.fNote.value || null
      });
      if (siteRes.error) throw siteRes.error;

      if (state.identity.isAdmin) {
        if (el.fInstaller.value) {
          // 설치업체를 지정하면 담당업체는 그 소속으로 서버에서 자동 동기화된다.
          var newInstallerId = parseInt(el.fInstaller.value, 10);
          var assignInstRes = await supabase.rpc("assign_installer", {
            p_token: token, p_site_id: siteId, p_installer_id: newInstallerId
          });
          if (assignInstRes.error) throw assignInstRes.error;
          var installer = state.installersList.find(function (i) { return i.id === newInstallerId; });
          site.installer_id = newInstallerId;
          site.group_id = installer ? installer.group_id : site.group_id;
        } else {
          // 설치업체가 미배정이면 담당업체만 별도로 저장한다.
          var newGroupId = el.fGroup.value ? parseInt(el.fGroup.value, 10) : null;
          var assignGroupRes = await supabase.rpc("assign_group", {
            p_token: token, p_site_id: siteId, p_group_id: newGroupId
          });
          if (assignGroupRes.error) throw assignGroupRes.error;
          site.installer_id = null;
          site.group_id = newGroupId;
        }
      }

      if (!state.installBysite[siteId]) state.installBysite[siteId] = {};
      if (!state.unitsBysite[siteId]) state.unitsBysite[siteId] = { B: [], C: [] };

      for (var i = 0; i < PRODUCTS.length; i++) {
        var product = PRODUCTS[i];
        var rowEl = el.productTbody.querySelector('tr[data-product="' + product + '"]');
        var qtyInput = rowEl.querySelector(".f-actual-qty");
        var qty = qtyInput.value === "" ? null : parseInt(qtyInput.value, 10);

        var instRes = await supabase.rpc("save_installation", {
          p_token: token,
          p_site_id: siteId,
          p_product: product,
          p_actual_qty: qty
        });
        if (instRes.error) throw instRes.error;

        if (!state.installBysite[siteId][product]) state.installBysite[siteId][product] = { planned_qty: 0 };
        state.installBysite[siteId][product].actual_qty = qty;

        if (product === "B" || product === "C") {
          var units = collectUnitsFromDom(product);
          var unitsRes = await supabase.rpc("save_installation_units", {
            p_token: token, p_site_id: siteId, p_product: product, p_units: units
          });
          if (unitsRes.error) throw unitsRes.error;
          state.unitsBysite[siteId][product] = units.map(function (u) { return Object.assign({ site_id: siteId, product: product }, u); });
        }
      }

      site.status = el.fStatus.value;
      site.install_date = el.fInstallDate.value || null;
      site.note = el.fNote.value || null;
      site.updated_by = state.identity.isAdmin
        ? "[관리자] " + (state.identity.installerName || state.identity.groupName || "마스터")
        : (state.identity.installerName || state.identity.groupName);
      site.updated_at = new Date().toISOString();

      el.saveAllMsg.textContent = "저장되었습니다.";
      el.saveAllMsg.className = "save-msg ok";
      el.detailMeta.textContent = "최종 수정: " + formatDateTime(site.updated_at);
      renderTable();
    } catch (e) {
      el.saveAllMsg.textContent = "저장 실패: " + (e.message || e);
      el.saveAllMsg.className = "save-msg err";
    } finally {
      el.saveAllBtn.disabled = false;
    }
  }

  // ---------- CSV export ----------
  function formatUnitsText(units, product) {
    var fields = UNIT_FIELDS[product];
    return units.slice().sort(function (x, y) { return x.unit_no - y.unit_no; }).map(function (u) {
      return u.unit_no + "번: " + fields.map(function (f) { return f.label + "=" + (u[f.key] || "-"); }).join(", ");
    }).join(" / ");
  }

  function exportCSV() {
    var header = ["담당업체", "사업장명", "설치업체", "상태", "설치일", "담당자명", "비고",
      "GST-502_예정", "GST-502_실제",
      "GX-8200_예정", "GX-8200_실제", "GX-8200_상세정보",
      "GX-8200 TCP/IP_예정", "GX-8200 TCP/IP_실제", "GX-8200 TCP/IP_상세정보",
      "최종수정자", "최종수정시각"];
    var rows = state.sites.map(function (s) {
      var inst = state.installBysite[s.id] || {};
      var a = inst.A || {}, b = inst.B || {}, c = inst.C || {};
      var installer = state.installersById[s.installer_id];
      var units = state.unitsBysite[s.id] || { B: [], C: [] };
      return [
        getEffectiveGroupName(s) || "", s.name, installer ? installer.name : "", s.status || "",
        s.install_date || "", s.manager_name || "", s.note || "",
        a.planned_qty ?? "", a.actual_qty ?? "",
        b.planned_qty ?? "", b.actual_qty ?? "", formatUnitsText(units.B || [], "B"),
        c.planned_qty ?? "", c.actual_qty ?? "", formatUnitsText(units.C || [], "C"),
        s.updated_by || "", s.updated_at ? formatDateTime(s.updated_at) : ""
      ];
    });

    var csvLines = [header].concat(rows).map(function (r) {
      return r.map(function (v) {
        var str = String(v ?? "");
        if (/[",\n]/.test(str)) str = '"' + str.replace(/"/g, '""') + '"';
        return str;
      }).join(",");
    });
    var csv = "﻿" + csvLines.join("\r\n");

    var blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = "설치현황_" + new Date().toISOString().slice(0, 10) + ".csv";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  // ---------- events ----------
  function bindEvents() {
    el.search.addEventListener("input", renderTable);
    el.filterStatus.addEventListener("change", renderTable);
    el.filterGroup.addEventListener("change", renderTable);
    el.filterInstaller.addEventListener("change", renderTable);
    el.exportBtn.addEventListener("click", exportCSV);

    el.groupStats.addEventListener("click", function (e) {
      var btn = e.target.closest(".calendar-btn");
      if (!btn) return;
      var groupId = parseInt(btn.getAttribute("data-group-id"), 10);
      var group = state.groupsList.find(function (g) { return g.id === groupId; });
      openScheduleWindow(groupId, group ? group.name : "");
    });

    el.sortInstallDateBtn.addEventListener("click", function () {
      state.installDateSort = state.installDateSort === "asc" ? "desc" : "asc";
      updateSortButton();
      renderTable();
    });

    // 설치업체를 고르면 담당업체는 그 소속으로 자동 동기화되고 잠기며,
    // 설치업체를 다시 미배정으로 되돌리면 담당업체를 직접 고를 수 있게 열어준다.
    el.fInstaller.addEventListener("change", function () {
      if (!state.identity.isAdmin) return;
      if (el.fInstaller.value) {
        var installer = state.installersList.find(function (i) { return String(i.id) === el.fInstaller.value; });
        el.fGroup.value = installer ? installer.group_id : "";
        el.fGroup.disabled = true;
      } else {
        el.fGroup.disabled = false;
      }
    });

    el.tbody.addEventListener("click", function (e) {
      var tr = e.target.closest("tr[data-site-id]");
      if (!tr) return;
      openDetail(parseInt(tr.getAttribute("data-site-id"), 10));
    });

    el.modalClose.addEventListener("click", closeDetail);
    el.modal.addEventListener("click", function (e) {
      if (e.target === el.modal) closeDetail();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !el.modal.classList.contains("hidden")) closeDetail();
    });

    el.saveAllBtn.addEventListener("click", handleSaveAll);
    el.productTbody.addEventListener("input", function (e) {
      if (!e.target.classList.contains("f-actual-qty")) return;
      var rowEl = e.target.closest("tr[data-product]");
      var product = rowEl.getAttribute("data-product");
      if (product !== "B") return; // C는 change(포커스 아웃)에서 처리 — 삭제 선택 플로우 때문
      renderUnits(product, state.activeSiteId, e.target.value, state.activeEditable);
    });
    el.productTbody.addEventListener("change", function (e) {
      if (!e.target.classList.contains("f-actual-qty")) return;
      var rowEl = e.target.closest("tr[data-product]");
      if (rowEl.getAttribute("data-product") !== "C") return;
      handleCActualQtyChange(e.target.value);
    });
    el.cUnitsList.addEventListener("focusout", function (e) {
      if (e.target.getAttribute("data-field") !== "mac_address") return;
      e.target.value = formatMacAddress(e.target.value);
    });
    el.cUnitsList.addEventListener("change", function (e) {
      if (!e.target.classList.contains("unit-remove-checkbox")) return;
      if (!state.cRemoval) return;
      var idx = parseInt(e.target.getAttribute("data-idx"), 10);
      state.cRemoval.units.splice(idx, 1);
      if (state.cRemoval.units.length <= state.cRemoval.target) exitCRemovalMode();
      else renderCRemovalUI();
    });
  }

  // ---------- init ----------
  async function init() {
    bindEvents();
    el.tbody.innerHTML = '<tr class="empty-row"><td colspan="10">불러오는 중...</td></tr>';
    try {
      await loadAll();
      renderIdentity();
      renderFilterOptions();
      renderTable();

      var hashMatch = /^#site-(\d+)$/.exec(window.location.hash);
      if (hashMatch) openDetail(parseInt(hashMatch[1], 10));
    } catch (e) {
      el.tbody.innerHTML = '<tr class="empty-row"><td colspan="10">데이터를 불러오지 못했습니다: ' + esc(e.message || e) + "</td></tr>";
      console.error(e);
    }
  }

  init();
})();
