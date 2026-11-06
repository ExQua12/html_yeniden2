/*

(() => {

    const accountActions = document.querySelector(".account-actions");
    const authModal = document.querySelector("#auth-modal");
    const authForm = document.querySelector("#auth-form");
    const authMessage = document.querySelector("#auth-message");
    const nameField = document.querySelector(".name-field");
    const authNotice = authModal ? document.createElement("div") : null;
    let authMode = "login";
    let accountPanel = null;
    let accountTrigger = null;
    const defaultAccountActions = accountActions ? accountActions.innerHTML : "";

    if (authNotice) {
        authNotice.className = "auth-error-notice";
        authNotice.setAttribute("role", "alert");
        authNotice.setAttribute("aria-live", "assertive");
        authNotice.hidden = true;
        document.body.append(authNotice);
    }

    function setAuthMode(mode) {
        authMode = mode;
        const isRegister = mode === "register";
        document.querySelector("#login-tab")?.setAttribute("aria-selected", String(!isRegister));
        document.querySelector("#register-tab")?.setAttribute("aria-selected", String(isRegister));
        if (nameField) {
            nameField.hidden = !isRegister;
            nameField.querySelector("input").required = isRegister;
        }
        const passwordInput = authForm?.elements.namedItem("password");
        if (passwordInput) passwordInput.autocomplete = isRegister ? "new-password" : "current-password";
        const title = document.querySelector("#auth-title");
        if (title) title.textContent = isRegister ? "Aramıza katıl." : "Tekrar hoş geldin.";
        const submit = document.querySelector("#auth-submit");
        if (submit) submit.innerHTML = `${isRegister ? "Kayıt ol" : "Giriş yap"} <span aria-hidden="true">→</span>`;
        clearAuthMessage();
    }

    function clearAuthMessage() {
        if (!authMessage) return;
        authMessage.textContent = "";
        authMessage.hidden = true;
        authMessage.classList.remove("is-error");
    }

    function showAuthMessage(message) {
        if (!authMessage) return;
        authMessage.textContent = message;
        authMessage.hidden = false;
        authMessage.classList.add("is-error");
    }

    function showLoginNotice(message) {
        if (!authNotice) return;
        authNotice.textContent = message;
        authNotice.hidden = false;
        authNotice.classList.remove("is-visible");
        requestAnimationFrame(() => authNotice.classList.add("is-visible"));
        clearTimeout(showLoginNotice.timer);
        showLoginNotice.timer = setTimeout(() => {
            authNotice.classList.remove("is-visible");
            setTimeout(() => { authNotice.hidden = true; }, 250);
        }, 4000);
    }

    function showToast(message) {
        const toast = document.querySelector("#toast");
        if (!toast) return;
        toast.textContent = message;
        toast.classList.add("is-visible");
        setTimeout(() => toast.classList.remove("is-visible"), 2800);
    }

    function setAccountPanelOpen(open) {
        if (!accountPanel || !accountTrigger) return;
        accountPanel.hidden = !open;
        accountTrigger.setAttribute("aria-expanded", String(open));
    }

    function getInitials(name) {
        const parts = name.trim().split(/\s+/).filter(Boolean);
        if (parts.length > 1) return `${parts[0][0]}${parts[parts.length - 1][0]}`.toLocaleUpperCase("tr-TR");
        return (parts[0] || "?").slice(0, 1).toLocaleUpperCase("tr-TR");
    }

    function formatCurrency(amount) {
        return `₺${Number(amount).toLocaleString("tr-TR")}`;
    }

    function formatOrderDate(value) {
        const date = new Date(value);
        return Number.isNaN(date.getTime()) ? "" : date.toLocaleDateString("tr-TR");
    }

    function updateProfileSaveButton(form) {
        const savedValues = JSON.parse(form.dataset.savedValues || "{}");
        const changed = [...form.querySelectorAll("input[name]")].some((input) => input.value.trim() !== (savedValues[input.name] || ""));
        const saveButton = form.querySelector(".profile-save");
        saveButton.classList.toggle("is-dirty", changed);
        saveButton.disabled = !changed;
    }

    async function loadOrders(panel) {
        const list = panel.querySelector(".account-orders-list");
        try {
            const response = await fetch("/api/orders", { headers: { Accept: "application/json" } });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || "Siparişler yüklenemedi.");
            list.replaceChildren();
            if (!result.orders.length) {
                const empty = document.createElement("p");
                empty.className = "orders-empty";
                empty.textContent = "Henüz bir siparişin yok. Beğendiğin motosikletleri sepetine ekleyebilirsin.";
                list.append(empty);
                return;
            }

            result.orders.forEach((order) => {
                const item = document.createElement("article");
                item.className = "account-order";
                const top = document.createElement("div");
                top.className = "account-order-top";
                const number = document.createElement("span");
                number.className = "account-order-number";
                number.textContent = order.number;
                const date = document.createElement("time");
                date.className = "account-order-date";
                date.dateTime = order.createdAt;
                date.textContent = formatOrderDate(order.createdAt);
                top.append(number, date);
                const items = document.createElement("p");
                items.className = "account-order-items";
                items.textContent = order.items.map((orderItem) => orderItem.name).join(", ");
                const total = document.createElement("div");
                total.className = "account-order-total";
                total.textContent = formatCurrency(order.total);
                item.append(top, items, total);
                list.append(item);
            });
        } catch (error) {
            list.replaceChildren();
            const message = document.createElement("p");
            message.className = "orders-empty is-error";
            message.textContent = error instanceof TypeError ? "Sipariş geçmişine şu an ulaşılamıyor." : error.message;
            list.append(message);
        }
    }

    async function saveProfile(event, panel) {
        event.preventDefault();
        const form = event.currentTarget;
        const saveButton = form.querySelector(".profile-save");
        const status = form.querySelector(".profile-status");
        status.textContent = "";
        status.className = "profile-status";
        saveButton.disabled = true;
        saveButton.textContent = "Kaydediliyor...";
        const payload = Object.fromEntries(new FormData(form).entries());

        try {
            const response = await fetch("/api/auth/profile", {
                method: "POST",
                headers: { "Content-Type": "application/json", Accept: "application/json" },
                body: JSON.stringify(payload)
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || "Bilgiler kaydedilemedi.");
            const displayName = result.user.name.trim().split(/\s+/)[0] || result.user.name;
            accountTrigger.querySelector(".account-avatar").textContent = getInitials(result.user.name);
            accountTrigger.setAttribute("aria-label", `Hesap: ${displayName}`);
            panel.querySelector(".account-panel-email").textContent = result.user.email;
            form.querySelector("[name='name']").value = result.user.name;
            form.querySelector("[name='email']").value = result.user.email;
            form.querySelector("[name='phone']").value = result.user.phone || "";
            form.dataset.savedValues = JSON.stringify({ name: result.user.name, email: result.user.email, phone: result.user.phone || "" });
            status.textContent = "İletişim bilgilerin güncellendi.";
            status.classList.add("is-success");
        } catch (error) {
            status.textContent = error instanceof TypeError ? "Sunucuya bağlanılamadı." : error.message;
            status.classList.add("is-error");
        } finally {
            saveButton.disabled = false;
            saveButton.textContent = "Bilgileri kaydet";
            updateProfileSaveButton(form);
        }
    }

    function renderAccount(user) {
        if (!accountActions) return;
        accountActions.replaceChildren();
        accountActions.classList.toggle("is-authenticated", Boolean(user));
        accountPanel = null;
        accountTrigger = null;
        if (!user) {
            accountActions.innerHTML = defaultAccountActions;
            return;
        }

        const displayName = user.name.trim().split(/\s+/)[0] || user.name;
        accountTrigger = document.createElement("button");
        accountTrigger.className = "account-trigger";
        accountTrigger.type = "button";
        accountTrigger.setAttribute("aria-label", `Hesap: ${displayName}`);
        accountTrigger.setAttribute("aria-haspopup", "dialog");
        accountTrigger.setAttribute("aria-expanded", "false");
        accountTrigger.setAttribute("aria-controls", "account-panel");
        const avatar = document.createElement("span");
        avatar.className = "account-avatar";
        avatar.setAttribute("aria-hidden", "true");
        avatar.textContent = getInitials(user.name);
        accountTrigger.append(avatar);

        accountPanel = document.createElement("section");
        accountPanel.className = "account-panel";
        accountPanel.id = "account-panel";
        accountPanel.setAttribute("role", "dialog");
        accountPanel.setAttribute("aria-label", "Hesap bilgileri");
        accountPanel.hidden = true;
        accountPanel.innerHTML = `
            <div class="account-panel-head">
                <div><h2>Hesabım</h2><p class="account-panel-email"></p></div>
                <button class="account-panel-close" type="button" aria-label="Hesap panelini kapat">×</button>
            </div>
            <form class="profile-form">
                <label>Ad soyad<input name="name" autocomplete="name" minlength="2" maxlength="80" required></label>
                <label>E-posta<input name="email" type="email" autocomplete="email" maxlength="254" required></label>
                <label>Telefon<input name="phone" type="tel" autocomplete="tel" maxlength="30" placeholder="İsteğe bağlı"></label>
                <p class="profile-status" role="status" aria-live="polite"></p>
                <button class="profile-save" type="submit">Bilgileri kaydet</button>
            </form>
            <section class="account-orders" aria-labelledby="account-orders-title">
                <h3 id="account-orders-title">Sipariş geçmişim</h3>
                <div class="account-orders-list" aria-live="polite"><p class="orders-empty">Siparişler yükleniyor...</p></div>
            </section>
            <button class="account-panel-logout" type="button">Çıkış yap</button>
        `;
        accountPanel.querySelector("[name='name']").value = user.name;
        accountPanel.querySelector("[name='email']").value = user.email;
        accountPanel.querySelector("[name='phone']").value = user.phone || "";
        accountPanel.querySelector(".account-panel-email").textContent = user.email;
        const profileForm = accountPanel.querySelector(".profile-form");
        profileForm.dataset.savedValues = JSON.stringify({ name: user.name, email: user.email, phone: user.phone || "" });
        profileForm.addEventListener("input", () => updateProfileSaveButton(profileForm));
        updateProfileSaveButton(profileForm);
        accountTrigger.addEventListener("click", () => setAccountPanelOpen(accountPanel.hidden));
        accountPanel.querySelector(".account-panel-close").addEventListener("click", () => setAccountPanelOpen(false));
        accountPanel.querySelector(".account-panel-logout").addEventListener("click", logout);
        accountPanel.querySelector(".profile-form").addEventListener("submit", (event) => saveProfile(event, accountPanel));
        accountActions.append(accountTrigger, accountPanel);
        loadOrders(accountPanel);
    }

    async function refreshAccount() {
        try {
            const response = await fetch("/api/auth/me", { headers: { Accept: "application/json" } });
            if (!response.ok) return;
            const result = await response.json();
            renderAccount(result.user);
        } catch {
            // Opening the files directly is unsupported for server-backed auth.
        }
    }

    async function logout() {
        try {
            await fetch("/api/auth/logout", { method: "POST" });
            renderAccount(null);
            showToast("Oturum kapatıldı.");
        } catch {
            showToast("Sunucuya bağlanılamadı.");
        }
    }

    if (accountActions) {
        accountActions.addEventListener("click", (event) => {
            const button = event.target.closest("[data-auth]");
            if (!button || !authModal) return;
            setAuthMode(button.dataset.auth);
            authModal.classList.add("is-open");
        });
    }

    document.querySelectorAll("[data-mode]").forEach((button) => {
        button.addEventListener("click", () => setAuthMode(button.dataset.mode));
    });
    document.querySelector(".modal-close")?.addEventListener("click", () => authModal?.classList.remove("is-open"));
    authModal?.addEventListener("click", (event) => {
        if (event.target === authModal) authModal.classList.remove("is-open");
    });
    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
            authModal?.classList.remove("is-open");
            setAccountPanelOpen(false);
        }
    });
    document.addEventListener("pointerdown", (event) => {
        if (accountPanel && !accountActions.contains(event.target)) setAccountPanelOpen(false);
    });

    authForm?.addEventListener("submit", async (event) => {
        event.preventDefault();
        clearAuthMessage();
        const submit = document.querySelector("#auth-submit");
        submit.disabled = true;
        submit.textContent = "Bekle...";
        const completedMode = authMode;
        const formData = new FormData(authForm);
        const payload = Object.fromEntries(formData.entries());

        try {
            const response = await fetch(`/api/auth/${completedMode}`, {
                method: "POST",
                headers: { "Content-Type": "application/json", Accept: "application/json" },
                body: JSON.stringify(payload)
            });
            const result = await response.json();
            if (!response.ok) {
                const requestError = new Error(result.error || "İstek tamamlanamadı.");
                requestError.status = response.status;
                throw requestError;
            }
            renderAccount(result.user);
            authModal.classList.remove("is-open");
            authForm.reset();
            setAuthMode("login");
            showToast(completedMode === "register" ? "Hesabın oluşturuldu." : "Giriş başarılı.");
        } catch (error) {
            const message = error instanceof TypeError ? "Sunucuya bağlanılamadı. Siteyi server.ps1 ile aç." : error.message;
            if (completedMode === "login") showLoginNotice(error.status === 401 ? "Giriş yapılamadı. E-posta veya şifre hatalı." : message);
            else showAuthMessage(message);
        } finally {
            submit.disabled = false;
            setAuthMode(authMode);
        }
    });

    if (location.hash === "#giris" || location.hash === "#kayit") {
        setAuthMode(location.hash === "#kayit" ? "register" : "login");
        authModal?.classList.add("is-open");
    }
    refreshAccount();
})(); */