package cms

import (
	"net/http"
)

func (c *CMS) HandleAdminUI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(adminHTML))
}

const adminHTML = `<!DOCTYPE html>
<html lang="uk">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VARTA CMS — Панель безпеки та адміністрування</title>
  <style>
    :root {
      --bg: #090C10;
      --surface: #121824;
      --card: #182030;
      --border: #232E42;
      --primary: #2563EB;
      --primary-hover: #1D4ED8;
      --gold: #F59E0B;
      --gold-hover: #D97706;
      --text: #F3F4F6;
      --text-muted: #9CA3AF;
      --danger: #EF4444;
      --success: #10B981;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: var(--bg); color: var(--text); min-height: 100vh; display: flex; }
    
    /* Sidebar */
    .sidebar { width: 260px; background: var(--surface); border-right: 1px solid var(--border); display: flex; flex-direction: column; }
    .brand { padding: 24px 20px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 12px; }
    .brand-icon { width: 36px; height: 36px; background: linear-gradient(135deg, var(--gold), var(--primary)); border-radius: 8px; display: flex; align-items: center; justify-content: center; font-size: 18px; font-weight: bold; }
    .brand-title { font-size: 18px; font-weight: 800; letter-spacing: 1px; color: var(--text); }
    .brand-sub { font-size: 11px; color: var(--gold); text-transform: uppercase; font-weight: 600; letter-spacing: 0.5px; }
    .nav { padding: 16px 8px; flex: 1; }
    .nav-item { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-radius: 8px; color: var(--text-muted); text-decoration: none; font-size: 14px; font-weight: 500; cursor: pointer; transition: 0.2s; margin-bottom: 4px; }
    .nav-item:hover, .nav-item.active { background: var(--card); color: var(--text); }
    .nav-item.active { color: var(--gold); border-left: 3px solid var(--gold); }
    
    /* Main Content */
    .content { flex: 1; display: flex; flex-direction: column; overflow-y: auto; height: 100vh; }
    .topbar { height: 64px; border-bottom: 1px solid var(--border); background: var(--surface); display: flex; align-items: center; justify-content: space-between; padding: 0 32px; }
    .topbar-title { font-size: 18px; font-weight: 700; }
    .status-badge { display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; background: rgba(16, 185, 129, 0.15); border: 1px solid var(--success); border-radius: 20px; color: var(--success); font-size: 12px; font-weight: 600; }
    .status-dot { width: 8px; height: 8px; background: var(--success); border-radius: 50%; box-shadow: 0 0 8px var(--success); }
    
    .page { padding: 32px; display: none; }
    .page.active { display: block; }
    
    /* Stats Grid */
    .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 32px; }
    .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }
    .stat-title { font-size: 13px; color: var(--text-muted); font-weight: 500; margin-bottom: 8px; }
    .stat-value { font-size: 32px; font-weight: 800; color: var(--text); }
    .stat-value.gold { color: var(--gold); }
    
    /* Tables & Cards */
    .card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin-bottom: 24px; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
    .card-title { font-size: 16px; font-weight: 700; }
    
    .btn { padding: 10px 18px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; border: none; transition: 0.2s; display: inline-flex; align-items: center; gap: 8px; }
    .btn-gold { background: var(--gold); color: #000; }
    .btn-gold:hover { background: var(--gold-hover); }
    .btn-danger { background: rgba(239, 68, 68, 0.15); color: var(--danger); border: 1px solid var(--danger); }
    .btn-danger:hover { background: var(--danger); color: #fff; }
    
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th { text-align: left; padding: 12px 14px; color: var(--text-muted); font-weight: 600; border-bottom: 1px solid var(--border); }
    td { padding: 14px; border-bottom: 1px solid var(--border); }
    tr:last-child td { border-bottom: none; }
    .token-code { font-family: monospace; background: var(--card); padding: 4px 8px; border-radius: 4px; color: var(--gold); border: 1px solid var(--border); }
    .badge { padding: 4px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
    .badge-success { background: rgba(16, 185, 129, 0.15); color: var(--success); }
    .badge-danger { background: rgba(239, 68, 68, 0.15); color: var(--danger); }
    
    /* Modal */
    .modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.7); display: none; align-items: center; justify-content: center; z-index: 1000; }
    .modal-overlay.active { display: flex; }
    .modal { background: var(--surface); border: 1px solid var(--border); border-radius: 14px; width: 440px; padding: 28px; }
    .modal-title { font-size: 18px; font-weight: 700; margin-bottom: 16px; }
    .form-group { margin-bottom: 16px; }
    .form-label { display: block; font-size: 12px; font-weight: 600; color: var(--text-muted); margin-bottom: 6px; }
    .form-input, .form-select { width: 100%; padding: 10px 14px; background: var(--card); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 14px; outline: none; }
    .form-input:focus, .form-select:focus { border-color: var(--gold); }
    .form-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 24px; }
  </style>
</head>
<body>
  <div class="sidebar">
    <div class="brand">
      <div class="brand-icon">🛡️</div>
      <div>
        <div class="brand-title">VARTA</div>
        <div class="brand-sub">Security CMS 1.0</div>
      </div>
    </div>
    <div class="nav">
      <div class="nav-item active" onclick="showTab('dashboard')">📊 Панель моніторингу</div>
      <div class="nav-item" onclick="showTab('invites')">🎟️ Одноразові інвайти</div>
      <div class="nav-item" onclick="showTab('users')">👥 Користувачі та сесії</div>
      <div class="nav-item" onclick="showTab('audit')">📜 Журнал аудиту</div>
    </div>
  </div>

  <div class="content">
    <div class="topbar">
      <div class="topbar-title" id="page-title">Панель моніторингу</div>
      <div class="status-badge">
        <div class="status-dot"></div>
        <span>E2EE Мережа Активна</span>
      </div>
    </div>

    <!-- 1. Dashboard -->
    <div class="page active" id="tab-dashboard">
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-title">Зареєстровано учасників</div>
          <div class="stat-value gold" id="stat-users">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-title">Підключено пристроїв</div>
          <div class="stat-value" id="stat-devices">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-title">Активних інвайтів</div>
          <div class="stat-value" id="stat-invites">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-title">Черга повідомлень (Offline)</div>
          <div class="stat-value" id="stat-messages">-</div>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <div class="card-title">Останні згенеровані інвайти</div>
          <button class="btn btn-gold" onclick="openInviteModal()">+ Створити інвайт</button>
        </div>
        <table>
          <thead>
            <tr>
              <th>Токен запрошення</th>
              <th>Роль</th>
              <th>Використання</th>
              <th>Строк дії</th>
              <th>Примітка</th>
              <th>Статус</th>
            </tr>
          </thead>
          <tbody id="dash-invites-table">
            <tr><td colspan="6" style="text-align: center; color: var(--text-muted);">Завантаження даних...</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- 2. Invites Page -->
    <div class="page" id="tab-invites">
      <div class="card">
        <div class="card-header">
          <div class="card-title">Керування запрошеннями спільноти</div>
          <button class="btn btn-gold" onclick="openInviteModal()">+ Новий інвайт</button>
        </div>
        <table>
          <thead>
            <tr>
              <th>Токен</th>
              <th>Роль</th>
              <th>Використано</th>
              <th>Строк дії</th>
              <th>Примітка</th>
              <th>Статус</th>
              <th>Дія</th>
            </tr>
          </thead>
          <tbody id="full-invites-table"></tbody>
        </table>
      </div>
    </div>

    <!-- 3. Users Page -->
    <div class="page" id="tab-users">
      <div class="card">
        <div class="card-header">
          <div class="card-title">Учасники захищеного чату</div>
        </div>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Логін</th>
              <th>Ім'я</th>
              <th>Роль</th>
              <th>Пристроїв</th>
              <th>Статус</th>
              <th>Дії</th>
            </tr>
          </thead>
          <tbody id="users-table"></tbody>
        </table>
      </div>
    </div>

    <!-- 4. Audit Page -->
    <div class="page" id="tab-audit">
      <div class="card">
        <div class="card-header">
          <div class="card-title">Журнал безпеки та подій системи</div>
        </div>
        <table>
          <thead>
            <tr>
              <th>Час</th>
              <th>Подія</th>
              <th>Адміністратор</th>
              <th>Деталі</th>
            </tr>
          </thead>
          <tbody id="audit-table"></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Create Invite Modal -->
  <div class="modal-overlay" id="invite-modal">
    <div class="modal">
      <div class="modal-title">Створення захищеного інвайту</div>
      <div class="form-group">
        <label class="form-label">Призначена роль</label>
        <select class="form-select" id="inv-role">
          <option value="member">Учасник (Member)</option>
          <option value="moderator">Модератор (Moderator)</option>
          <option value="admin">Адміністратор (Admin)</option>
        </select>
      </div>
      <div class="form-group">
        <label class="form-label">Кількість використань</label>
        <input type="number" class="form-input" id="inv-uses" value="1" min="1" max="100">
      </div>
      <div class="form-group">
        <label class="form-label">Строк дії (днів, 0 = без обмежень)</label>
        <input type="number" class="form-input" id="inv-days" value="7" min="0" max="365">
      </div>
      <div class="form-group">
        <label class="form-label">Примітка / Для кого</label>
        <input type="text" class="form-input" id="inv-note" placeholder="Наприклад: для оператора дронів #3">
      </div>
      <div class="form-actions">
        <button class="btn" style="background: var(--card); color: var(--text);" onclick="closeInviteModal()">Скасувати</button>
        <button class="btn btn-gold" onclick="submitInvite()">Згенерувати інвайт</button>
      </div>
    </div>
  </div>

  <script>
    let currentTab = 'dashboard';

    function showTab(tab) {
      document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
      document.querySelectorAll('.page').forEach(el => el.classList.remove('active'));
      
      const tabEl = document.getElementById('tab-' + tab);
      if (tabEl) tabEl.classList.add('active');
      
      event.currentTarget.classList.add('active');
      
      const titles = {
        'dashboard': 'Панель моніторингу',
        'invites': 'Одноразові інвайти',
        'users': 'Користувачі та сесії',
        'audit': 'Журнал аудиту'
      };
      document.getElementById('page-title').innerText = titles[tab] || 'VARTA CMS';
      currentTab = tab;
      loadData();
    }

    async function loadData() {
      try {
        const statsRes = await fetch('/api/v1/admin/stats');
        if (statsRes.ok) {
          const stats = await statsRes.json();
          document.getElementById('stat-users').innerText = stats.users_count;
          document.getElementById('stat-devices').innerText = stats.devices_count;
          document.getElementById('stat-invites').innerText = stats.active_invites;
          document.getElementById('stat-messages').innerText = stats.pending_messages;
        }

        const invRes = await fetch('/api/v1/admin/invites');
        if (invRes.ok) {
          const list = await invRes.json();
          renderInvites(list);
        }

        if (currentTab === 'users') {
          const uRes = await fetch('/api/v1/admin/users');
          if (uRes.ok) renderUsers(await uRes.json());
        }

        if (currentTab === 'audit') {
          const aRes = await fetch('/api/v1/admin/audit');
          if (aRes.ok) renderAudit(await aRes.json());
        }
      } catch (e) {
        console.error('Error loading data:', e);
      }
    }

    function renderInvites(list) {
      const renderRow = (inv) => {
        const isExpired = inv.expires_at && new Date(inv.expires_at) < new Date();
        const isExhausted = inv.uses_count >= inv.max_uses;
        const isValid = !inv.is_revoked && !isExpired && !isExhausted;

        let badge = '<span class="badge badge-success">Дійсний</span>';
        if (inv.is_revoked) badge = '<span class="badge badge-danger">Відкликано</span>';
        else if (isExpired) badge = '<span class="badge badge-danger">Прострочено</span>';
        else if (isExhausted) badge = '<span class="badge badge-danger">Вичерпано</span>';

        return `
          <tr>
            <td><span class="token-code">${inv.token}</span> <button style="cursor:pointer; background:none; border:none; color:var(--gold);" onclick="copyToken('${inv.token}')" title="Копіювати">📋</button></td>
            <td><strong>${inv.role}</strong></td>
            <td>${inv.uses_count} / ${inv.max_uses}</td>
            <td>${inv.expires_at ? new Date(inv.expires_at).toLocaleDateString('uk-UA') : 'Необмежено'}</td>
            <td>${inv.note || '-'}</td>
            <td>${badge}</td>
            ${currentTab === 'invites' ? '<td>' + (isValid ? '<button class="btn btn-danger" style="padding:4px 8px; font-size:11px;" onclick="revokeInvite(' + inv.id + ')">Відкликати</button>' : '-') + '</td>' : ''}
          </tr>
        `;
      };

      const rows = list.map(renderRow).join('');
      const dashTable = document.getElementById('dash-invites-table');
      if (dashTable) dashTable.innerHTML = rows || '<tr><td colspan="6" style="text-align:center;">Немає згенерованих інвайтів</td></tr>';
      
      const fullTable = document.getElementById('full-invites-table');
      if (fullTable) fullTable.innerHTML = rows || '<tr><td colspan="7" style="text-align:center;">Немає запрошень</td></tr>';
    }

    function renderUsers(list) {
      const tbody = document.getElementById('users-table');
      tbody.innerHTML = list.map(u => `
        <tr>
          <td>${u.id}</td>
          <td><strong>${u.username}</strong></td>
          <td>${u.display_name}</td>
          <td><span class="token-code">${u.role}</span></td>
          <td>${u.device_count} пристрій(ів)</td>
          <td>${u.is_active ? '<span class="badge badge-success">Активний</span>' : '<span class="badge badge-danger">Заблоковано</span>'}</td>
          <td>
            <button class="btn btn-danger" style="padding:4px 8px; font-size:11px;" onclick="toggleUser(${u.id})">${u.is_active ? 'Заблокувати' : 'Розблокувати'}</button>
          </td>
        </tr>
      `).join('') || '<tr><td colspan="7" style="text-align:center;">Немає користувачів</td></tr>';
    }

    function renderAudit(list) {
      const tbody = document.getElementById('audit-table');
      tbody.innerHTML = list.map(a => `
        <tr>
          <td>${new Date(a.created_at).toLocaleString('uk-UA')}</td>
          <td><strong>${a.action}</strong></td>
          <td>Адмін #${a.user_id || 'System'}</td>
          <td><code>${JSON.stringify(a.details)}</code></td>
        </tr>
      `).join('') || '<tr><td colspan="4" style="text-align:center;">Записи відсутні</td></tr>';
    }

    function openInviteModal() { document.getElementById('invite-modal').classList.add('active'); }
    function closeInviteModal() { document.getElementById('invite-modal').classList.remove('active'); }

    async function submitInvite() {
      const role = document.getElementById('inv-role').value;
      const max_uses = parseInt(document.getElementById('inv-uses').value) || 1;
      const valid_days = parseInt(document.getElementById('inv-days').value) || 0;
      const note = document.getElementById('inv-note').value;

      try {
        const res = await fetch('/api/v1/admin/invites', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ role, max_uses, valid_days, note })
        });
        if (res.ok) {
          closeInviteModal();
          loadData();
        } else {
          alert('Помилка генерації інвайту');
        }
      } catch (e) {
        alert('Помилка: ' + e);
      }
    }

    async function revokeInvite(id) {
      if (!confirm('Ви дійсно бажаєте відкликати це запрошення?')) return;
      await fetch('/api/v1/admin/invites/' + id, { method: 'DELETE' });
      loadData();
    }

    async function toggleUser(id) {
      if (!confirm('Змінити статус активності користувача?')) return;
      await fetch('/api/v1/admin/users/' + id + '/toggle', { method: 'POST' });
      loadData();
    }

    function copyToken(token) {
      navigator.clipboard.writeText(token);
      alert('Інвайт скопійовано: ' + token);
    }

    // Auto load on init
    loadData();
  </script>
</body>
</html>
`
