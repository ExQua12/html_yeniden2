$ErrorActionPreference = "Stop"

$script:siteRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:dataRoot = Join-Path $script:siteRoot "data"
$script:usersFile = Join-Path $script:dataRoot "users.json"
$script:users = @()
$script:sessions = @{}
$script:iterations = 310000
$script:sessionLifetimeSeconds = 604800
$script:productPrices = @{
	"Vortex R9" = 489900
	"Nova 650" = 329500
	"Atlas X7" = 415000
	"Veloce GT" = 367900
	"Terra 500" = 248500
	"Raven S" = 529000
	"Arden 800" = 398000
	"Atlas Touring" = 446500
	"Forma 700" = 352900
}

New-Item -ItemType Directory -Path $script:dataRoot -Force | Out-Null
if (Test-Path $script:usersFile) {
	$storedUsers = Get-Content -LiteralPath $script:usersFile -Raw -Encoding UTF8 | ConvertFrom-Json
	if ($null -ne $storedUsers) {
		$script:users = @($storedUsers)
	}
}

function Write-JsonResponse {
	param(
		[System.Net.HttpListenerResponse]$Response,
		[int]$StatusCode,
		[object]$Value
	)

	$Response.StatusCode = $StatusCode
	$Response.ContentType = "application/json; charset=utf-8"
	$Response.Headers["Cache-Control"] = "no-store"
	$Response.Headers["X-Content-Type-Options"] = "nosniff"
	$bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Compress -Depth 6))
	$Response.ContentLength64 = $bytes.Length
	$Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-ErrorResponse {
	param(
		[System.Net.HttpListenerResponse]$Response,
		[int]$StatusCode,
		[string]$Message
	)

	Write-JsonResponse -Response $Response -StatusCode $StatusCode -Value @{ error = $Message }
}

function Read-JsonBody {
	param([System.Net.HttpListenerRequest]$Request)

	if ($Request.ContentLength64 -gt 8192) {
		throw "İstek boyutu çok büyük."
	}
	$reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
	try {
		$rawBody = $reader.ReadToEnd()
	}
	finally {
		$reader.Dispose()
	}
	return (ConvertFrom-Json -InputObject $rawBody)
}

function Get-EmailKey {
	param([string]$Email)

	$normalized = $Email.Trim().ToLowerInvariant()
	$parts = $normalized.Split("@", 2)
	if ($parts.Length -ne 2) { return $normalized }
	$localPart = $parts[0]
	$domain = $parts[1]
	if ($domain -eq "gmail.com" -or $domain -eq "googlemail.com") {
		$plusIndex = $localPart.IndexOf("+")
		if ($plusIndex -ge 0) { $localPart = $localPart.Substring(0, $plusIndex) }
		$localPart = $localPart.Replace(".", "")
		$domain = "gmail.com"
	}
	return "$localPart@$domain"
}

function Find-UserByEmail {
	param([string]$Email)

	$emailKey = Get-EmailKey -Email $Email
	foreach ($user in $script:users) {
		$storedEmailKey = [string]$user.emailKey
		if ([string]::IsNullOrWhiteSpace($storedEmailKey)) { $storedEmailKey = Get-EmailKey -Email $user.email }
		if ($storedEmailKey -eq $emailKey) {
			return $user
		}
	}
	return $null
}

function Get-PasswordHash {
	param(
		[string]$Password,
		[string]$SaltBase64
	)

	$passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
	$saltBytes = [System.Convert]::FromBase64String($SaltBase64)
	$deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
		$passwordBytes,
		$saltBytes,
		$script:iterations,
		[System.Security.Cryptography.HashAlgorithmName]::SHA256
	)
	try {
		return [System.Convert]::ToBase64String($deriveBytes.GetBytes(32))
	}
	finally {
		$deriveBytes.Dispose()
	}
}

function Test-Password {
	param(
		[string]$Password,
		[string]$SaltBase64,
		[string]$ExpectedHashBase64
	)

	$actual = [System.Convert]::FromBase64String((Get-PasswordHash -Password $Password -SaltBase64 $SaltBase64))
	$expected = [System.Convert]::FromBase64String($ExpectedHashBase64)
	if ($actual.Length -ne $expected.Length) {
		return $false
	}
	$difference = 0
	for ($index = 0; $index -lt $actual.Length; $index++) {
		$difference = $difference -bor ($actual[$index] -bxor $expected[$index])
	}
	return ($difference -eq 0)
}

function Save-Users {
	$json = ConvertTo-Json -InputObject ([object[]]$script:users) -Depth 5
	$tempFile = "$($script:usersFile).tmp"
	[System.IO.File]::WriteAllText($tempFile, $json, (New-Object System.Text.UTF8Encoding($false)))
	Move-Item -LiteralPath $tempFile -Destination $script:usersFile -Force
}

function Initialize-UserFields {
	$changed = $false
	foreach ($user in $script:users) {
		$emailKey = Get-EmailKey -Email $user.email
		if ($null -eq $user.PSObject.Properties["emailKey"]) {
			$user | Add-Member -MemberType NoteProperty -Name emailKey -Value $emailKey
			$changed = $true
		}
		elseif ($user.emailKey -ne $emailKey) {
			$user.emailKey = $emailKey
			$changed = $true
		}
		if ($null -eq $user.PSObject.Properties["phone"]) {
			$user | Add-Member -MemberType NoteProperty -Name phone -Value ""
			$changed = $true
		}
		if ($null -eq $user.PSObject.Properties["orders"]) {
			$user | Add-Member -MemberType NoteProperty -Name orders -Value ([object[]]@())
			$changed = $true
		}
	}
	if ($changed) {
		Save-Users
	}
}

Initialize-UserFields

function Get-PublicUser {
	param([object]$User)

	return @{
		id = $User.id
		name = $User.name
		email = $User.email
		phone = $User.phone
		createdAt = $User.createdAt
	}
}

function Get-SessionToken {
	param([System.Net.HttpListenerRequest]$Request)

	$cookieHeader = $Request.Headers["Cookie"]
	if ([string]::IsNullOrWhiteSpace($cookieHeader)) {
		return $null
	}
	foreach ($cookiePart in ($cookieHeader -split ";")) {
		$parts = $cookiePart.Trim().Split("=", 2)
		if ($parts.Length -eq 2 -and $parts[0] -eq "rota_session") {
			return $parts[1]
		}
	}
	return $null
}

function Get-SessionUser {
	param([System.Net.HttpListenerRequest]$Request)

	$token = Get-SessionToken -Request $Request
	if ([string]::IsNullOrWhiteSpace($token) -or -not $script:sessions.ContainsKey($token)) {
		return $null
	}
	$session = $script:sessions[$token]
	if ((Get-Date) -gt $session.expiresAt) {
		$script:sessions.Remove($token)
		return $null
	}
	foreach ($user in $script:users) {
		if ($user.id -eq $session.userId) {
			return $user
		}
	}
	$script:sessions.Remove($token)
	return $null
}

function New-Session {
	param(
		[System.Net.HttpListenerContext]$Context,
		[object]$User
	)

	$tokenBytes = New-Object byte[] 32
	$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	try {
		$random.GetBytes($tokenBytes)
	}
	finally {
		$random.Dispose()
	}
	$token = [System.Convert]::ToBase64String($tokenBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
	$script:sessions[$token] = @{
		userId = $User.id
		expiresAt = (Get-Date).AddSeconds($script:sessionLifetimeSeconds)
	}
	$Context.Response.AppendHeader("Set-Cookie", "rota_session=$token; Path=/; HttpOnly; SameSite=Lax; Max-Age=$($script:sessionLifetimeSeconds)")
	Write-JsonResponse -Response $Context.Response -StatusCode 200 -Value @{ user = (Get-PublicUser -User $User) }
}

function Test-SameOrigin {
	param([System.Net.HttpListenerContext]$Context)

	$origin = $Context.Request.Headers["Origin"]
	if ([string]::IsNullOrWhiteSpace($origin)) {
		return $true
	}
	return ($origin -eq $Context.Request.Url.GetLeftPart([System.UriPartial]::Authority))
}

function Invoke-AuthRoute {
	param([System.Net.HttpListenerContext]$Context)

	$request = $Context.Request
	$response = $Context.Response
	$path = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath)

	if ($path -eq "/api/auth/me" -and $request.HttpMethod -eq "GET") {
		$user = Get-SessionUser -Request $request
		if ($null -eq $user) {
			Write-JsonResponse -Response $response -StatusCode 200 -Value @{ user = $null }
		}
		else {
			Write-JsonResponse -Response $response -StatusCode 200 -Value @{ user = (Get-PublicUser -User $user) }
		}
		return
	}
	if ($path -eq "/api/orders" -and $request.HttpMethod -eq "GET") {
		$user = Get-SessionUser -Request $request
		if ($null -eq $user) {
			Write-ErrorResponse -Response $response -StatusCode 401 -Message "Sipariş geçmişini görmek için giriş yap."
			return
		}
		$orders = @($user.orders | Sort-Object -Property createdAt -Descending)
		Write-JsonResponse -Response $response -StatusCode 200 -Value @{ orders = $orders }
		return
	}

	if (-not (Test-SameOrigin -Context $Context)) {
		Write-ErrorResponse -Response $response -StatusCode 403 -Message "İstek kaynağı doğrulanamadı."
		return
	}
	if ($request.HttpMethod -ne "POST") {
		Write-ErrorResponse -Response $response -StatusCode 405 -Message "Bu istek yöntemi desteklenmiyor."
		return
	}

	if ($path -eq "/api/auth/logout") {
		$token = Get-SessionToken -Request $request
		if ($token -and $script:sessions.ContainsKey($token)) {
			$script:sessions.Remove($token)
		}
		$response.AppendHeader("Set-Cookie", "rota_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")
		Write-JsonResponse -Response $response -StatusCode 200 -Value @{ user = $null }
		return
	}

	if ($path -eq "/api/auth/profile") {
		$user = Get-SessionUser -Request $request
		if ($null -eq $user) {
			Write-ErrorResponse -Response $response -StatusCode 401 -Message "İletişim bilgilerini güncellemek için giriş yap."
			return
		}
		try {
			$body = Read-JsonBody -Request $request
		}
		catch {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Form bilgileri okunamadı."
			return
		}

		$name = ([string]$body.name).Trim()
		$email = ([string]$body.email).Trim().ToLowerInvariant()
		$phone = ([string]$body.phone).Trim()
		if ($name.Length -lt 2 -or $name.Length -gt 80) {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Ad soyad 2 ile 80 karakter arasında olmalı."
			return
		}
		if ($email.Length -gt 254 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Geçerli bir e-posta adresi gir."
			return
		}
		if ($phone.Length -gt 30 -or ($phone.Length -gt 0 -and ($phone.Length -lt 6 -or $phone -notmatch '^[0-9+()\s-]+$'))) {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Telefon numarasını kontrol et."
			return
		}
		$existingUser = Find-UserByEmail -Email $email
		if ($null -ne $existingUser -and $existingUser.id -ne $user.id) {
			Write-ErrorResponse -Response $response -StatusCode 409 -Message "Bu e-posta adresi başka bir hesapta kullanılıyor."
			return
		}
		$user.name = $name
		$user.email = $email
		$user.emailKey = Get-EmailKey -Email $email
		$user.phone = $phone
		Save-Users
		Write-JsonResponse -Response $response -StatusCode 200 -Value @{ user = (Get-PublicUser -User $user) }
		return
	}

	if ($path -eq "/api/orders") {
		$user = Get-SessionUser -Request $request
		if ($null -eq $user) {
			Write-ErrorResponse -Response $response -StatusCode 401 -Message "Sipariş oluşturmak için giriş yap."
			return
		}
		try {
			$body = Read-JsonBody -Request $request
		}
		catch {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Sipariş bilgileri okunamadı."
			return
		}
		$items = @($body.items)
		if ($items.Count -lt 1 -or $items.Count -gt 25) {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Sepetinde sipariş edilecek ürün bulunamadı."
			return
		}
		$orderItems = @()
		$total = [long]0
		foreach ($item in $items) {
			$itemName = ([string]$item.name).Trim()
			if (-not $script:productPrices.ContainsKey($itemName)) {
				Write-ErrorResponse -Response $response -StatusCode 400 -Message "Sepette geçersiz bir ürün var."
				return
			}
			$expectedPrice = [long]$script:productPrices[$itemName]
			try {
				$submittedPrice = [long]$item.price
			}
			catch {
				Write-ErrorResponse -Response $response -StatusCode 400 -Message "Ürün fiyatı doğrulanamadı."
				return
			}
			if ($submittedPrice -ne $expectedPrice) {
				Write-ErrorResponse -Response $response -StatusCode 400 -Message "Ürün fiyatı güncel değil; sepetini yenile."
				return
			}
			$orderItems += [pscustomobject]@{ name = $itemName; price = $expectedPrice }
			$total += $expectedPrice
		}

		$order = [pscustomobject]@{
			id = [guid]::NewGuid().ToString()
			number = "RM-$(Get-Date -Format 'yyMMdd')-$([guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant())"
			createdAt = (Get-Date).ToUniversalTime().ToString("o")
			items = $orderItems
			total = $total
		}
		$user.orders = @($user.orders) + @($order)
		Save-Users
		Write-JsonResponse -Response $response -StatusCode 201 -Value @{ order = $order }
		return
	}

	if ($path -ne "/api/auth/register" -and $path -ne "/api/auth/login") {
		Write-ErrorResponse -Response $response -StatusCode 404 -Message "İstek bulunamadı."
		return
	}

	try {
		$body = Read-JsonBody -Request $request
	}
	catch {
		Write-ErrorResponse -Response $response -StatusCode 400 -Message "Form bilgileri okunamadı."
		return
	}

	$email = ([string]$body.email).Trim().ToLowerInvariant()
	$password = [string]$body.password
	if ($email.Length -gt 254 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
		Write-ErrorResponse -Response $response -StatusCode 400 -Message "Geçerli bir e-posta adresi gir."
		return
	}
	if ($password.Length -lt 8 -or $password.Length -gt 128) {
		Write-ErrorResponse -Response $response -StatusCode 400 -Message "Şifre 8 ile 128 karakter arasında olmalı."
		return
	}

	if ($path -eq "/api/auth/register") {
		$name = ([string]$body.name).Trim()
		if ($name.Length -lt 2 -or $name.Length -gt 80) {
			Write-ErrorResponse -Response $response -StatusCode 400 -Message "Ad soyad 2 ile 80 karakter arasında olmalı."
			return
		}
		if ($null -ne (Find-UserByEmail -Email $email)) {
			Write-ErrorResponse -Response $response -StatusCode 409 -Message "Bu e-posta veya Gmail adresinin takma adıyla zaten bir hesap var."
			return
		}

		$saltBytes = New-Object byte[] 16
		$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
		try {
			$random.GetBytes($saltBytes)
		}
		finally {
			$random.Dispose()
		}
		$salt = [System.Convert]::ToBase64String($saltBytes)
		$user = [pscustomobject]@{
			id = [guid]::NewGuid().ToString()
			name = $name
			email = $email
			emailKey = Get-EmailKey -Email $email
			phone = ""
			orders = @()
			salt = $salt
			passwordHash = Get-PasswordHash -Password $password -SaltBase64 $salt
			createdAt = (Get-Date).ToUniversalTime().ToString("o")
		}
		$script:users = @($script:users) + @($user)
		Save-Users
		New-Session -Context $Context -User $user
		return
	}

	$user = Find-UserByEmail -Email $email
	if ($null -eq $user) {
		[void](Get-PasswordHash -Password $password -SaltBase64 "MDEyMzQ1Njc4OWFiY2RlZg==")
		Write-ErrorResponse -Response $response -StatusCode 401 -Message "E-posta veya şifre hatalı."
		return
	}
	if (-not (Test-Password -Password $password -SaltBase64 $user.salt -ExpectedHashBase64 $user.passwordHash)) {
		Write-ErrorResponse -Response $response -StatusCode 401 -Message "E-posta veya şifre hatalı."
		return
	}
	New-Session -Context $Context -User $user
}

function Write-StaticFile {
	param([System.Net.HttpListenerContext]$Context)

	$requestPath = [System.Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath).TrimStart("/")
	if ([string]::IsNullOrWhiteSpace($requestPath)) {
		$requestPath = "index.html"
	}
	$filePath = [System.IO.Path]::GetFullPath((Join-Path $script:siteRoot $requestPath))
	$rootPrefix = $script:siteRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
	if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
		$Context.Response.StatusCode = 404
		$Context.Response.ContentType = "text/plain; charset=utf-8"
		return
	}

	$extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
	if ($extension -notin @(".html", ".js", ".css", ".json", ".webmanifest", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico")) {
		$Context.Response.StatusCode = 404
		$Context.Response.ContentType = "text/plain; charset=utf-8"
		return
	}
	$contentType = switch ($extension) {
		".html" { "text/html; charset=utf-8"; break }
		".js" { "text/javascript; charset=utf-8"; break }
		".css" { "text/css; charset=utf-8"; break }
		".json" { "application/json; charset=utf-8"; break }
		".webmanifest" { "application/manifest+json; charset=utf-8"; break }
		".png" { "image/png"; break }
		".jpg" { "image/jpeg"; break }
		".jpeg" { "image/jpeg"; break }
		".gif" { "image/gif"; break }
		".webp" { "image/webp"; break }
		".ico" { "image/x-icon"; break }
		default { "application/octet-stream" }
	}
	$bytes = [System.IO.File]::ReadAllBytes($filePath)
	$Context.Response.StatusCode = 200
	$Context.Response.ContentType = $contentType
	$Context.Response.Headers["Cache-Control"] = "no-store"
	$Context.Response.Headers["X-Content-Type-Options"] = "nosniff"
	$Context.Response.ContentLength64 = $bytes.Length
	if ($Context.Request.HttpMethod -ne "HEAD") {
		$Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
	}
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:8787/")
$listener.Start()
Write-Host "ROTA MOTOR authentication server: http://127.0.0.1:8787"
Write-Host "User records and password hashes are stored in data/users.json. Press Ctrl+C to stop."

try {
	while ($listener.IsListening) {
		$context = $listener.GetContext()
		try {
			$path = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
			if ($path.StartsWith("/api/", [System.StringComparison]::Ordinal)) {
				Invoke-AuthRoute -Context $context
			}
			elseif ($context.Request.HttpMethod -eq "GET" -or $context.Request.HttpMethod -eq "HEAD") {
				Write-StaticFile -Context $context
			}
			else {
				Write-ErrorResponse -Response $context.Response -StatusCode 405 -Message "Bu istek yöntemi desteklenmiyor."
			}
		}
		catch {
			Write-Host "İstek işlenemedi: $($_.Exception.Message)"
			try {
				Write-ErrorResponse -Response $context.Response -StatusCode 500 -Message "Sunucu isteği tamamlayamadı."
			}
			catch { }
		}
		finally {
			$context.Response.Close()
		}
	}
}
finally {
	$listener.Stop()
	$listener.Close()
}