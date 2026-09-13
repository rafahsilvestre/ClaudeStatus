// ClaudeBarLocal.swift
//
// Menu bar do Claude Code.
//
// Quatro fontes, da mais viva para a mais teimosa:
//
//   1. API (fonte viva, sob demanda)
//        GET https://api.anthropic.com/api/oauth/usage.
//        Dispara quando VOCE abre o painel, com piso de 60s: o instante em que
//        alguem olha e o unico que justifica gastar requisicao num endpoint que
//        castiga polling com 429 de 30+ min. O timer de 300s continua existindo,
//        mas fica em silencio enquanto a fonte 2 estiver fresca -- ele volta a
//        poleiar sozinho para quem nao tem o app nativo, ou quando ele esta
//        fechado. Ver Store.maybeFetchAPI.
//        O token sai do Keychain -- mas lido por /usr/bin/security, nao pela API
//        SecItem. Ver Token.read() abaixo: e isso que elimina o dialogo
//        "Permitir sempre" que voltava a cada reboot.
//
//   2. Historico do app nativo do Claude (a fonte passiva boa)
//        ~/Library/Application Support/Claude/plan-usage-history.json
//        O app poleia /api/organizations/<org>/usage a cada 300s por conta
//        propria e guarda 30 dias de amostras. Ler custa zero requisicao e zero
//        credencial. So porcentagem: nao ha resets_at, e so anda com o app
//        aberto (maquina dormindo abre buraco na serie).
//
//   3. Cache do proprio Claude Code (arranque instantaneo e rede de seguranca)
//        ~/.claude.json -> cachedUsageUtilization
//        O Claude Code guarda ali a ultima resposta crua de /api/oauth/usage,
//        com throttle de 5 min na escrita. So e reescrito quando algum processo
//        do Claude Code busca usage de fato -- sessao de terminal ou
//        `claude -p /usage`. Trabalhar no VS Code nao atualiza esse valor: ja foi
//        visto com 11h de idade enquanto a fonte 2 seguia fresca.
//
//   4. Disco (escrito pela statusline e pelos hooks)
//        ~/.claude/claude-bar/usage.json        -> limites 5h/7d (ultimo recurso)
//        ~/.claude/claude-bar/sessions/*.json   -> estado de cada sessao
//        A statusline so roda no CLI: a invocacao dela vive dentro da TUI, entao
//        nem a extensao do VS Code nem o app nativo a executam. Por isso ela e o
//        ultimo fallback, nao o primeiro.
//
// O painel mostra sempre a mais fresca das quatro, com origem e idade. Os campos
// que a vencedora nao sabe carregar (resets_at, creditos extra) sao herdados --
// ver Store.publishUsage, que explica quando herdar seria mentira.
//
// Custo e tokens saem de uma quarta fonte, independente das outras:
//        ~/.claude/projects/**/*.jsonl -> transcripts do Claude Code
// Cada mensagem do assistente carrega o `usage` completo e o `cwd` do projeto.
// Leitura pura, sem rede e sem credencial; o preco e tabela fixa no codigo.
//
// O que ele NAO faz:
//   - nunca renova o token (o Claude Code e dono desse ciclo de vida; disputar
//     isso pode invalidar a sua sessao). Token expirado -> cai para o disco.
//   - nunca guarda o token: le, usa e descarta a cada ciclo
//   - nunca escreve em ~/.claude (a unica escrita e a preferencia de exibicao,
//     em ~/Library/Preferences/local.claudebar.plist)
//   - nunca decide permissao (quem aprova e voce, no terminal)
//
// Compilar: ./build.sh   (precisa de Xcode Command Line Tools)
// Requer macOS 13+.

import Foundation
import SwiftUI

// MARK: - Constantes

private enum K {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
    static let anthropicBeta = "oauth-2025-04-20"

    /// O User-Agent nao e cosmetico: sem `claude-code/<versao>` a requisicao cai
    /// num bucket de rate limit muito mais agressivo e o endpoint devolve 429.
    static let userAgent = "claude-code/2.1.220"

    /// Nunca descer disso. O endpoint castiga polling: ha relato de 429 em
    /// intervalos de 30s a 300s persistindo por 30+ minutos, sem Retry-After.
    static let apiInterval: TimeInterval = 300
    static let apiBackoffFloor: TimeInterval = 600    // primeiro passo apos 429
    static let apiBackoffCeiling: TimeInterval = 3600 // teto do backoff
    static let authRetry: TimeInterval = 300          // token expirado/ilegivel

    /// Teto para o /usr/bin/security responder. Ele nao deveria travar, mas um
    /// subprocesso pendurado seguraria a fila de IO para sempre.
    static let securityTimeout: TimeInterval = 8

    /// Chave dentro do ~/.claude.json onde o Claude Code guarda a ultima
    /// resposta de /api/oauth/usage.
    static let cacheKey = "cachedUsageUtilization"

    static let fileInterval: TimeInterval = 5
    static let staleAfter: TimeInterval = 60 * 60 * 6 // sessao sem SessionEnd
    static let dataStale: TimeInterval = 60 * 15      // dado velho -> esmaece

    /// Piso entre dois refreshes disparados por abrir o painel. Clique e ritmo
    /// humano, entao 60s aqui nao chega perto do polling que provoca 429 -- mas
    /// impede que abrir e fechar o painel em sequencia vire uma rajada.
    static let panelRefreshFloor: TimeInterval = 60

    /// Ate quando o historico do app nativo conta como fonte viva. Ele amostra a
    /// cada 300s; a folga cobre o jitter sem deixar o poller dormir alem de um
    /// ciclo perdido.
    static let passiveFresh: TimeInterval = 420
}

// MARK: - Modelo

enum SessionState: String {
    case waiting, working, done, idle

    /// Menor numero = maior prioridade na menu bar.
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .done:    return 2
        case .idle:    return 3
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "exclamationmark.circle.fill"
        case .working: return "circle.dotted"
        case .done:    return "checkmark.circle"
        case .idle:    return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .waiting: return .orange
        case .working: return .blue
        case .done:    return .green
        case .idle:    return .secondary
        }
    }

    /// Paleta do icone da menu bar -- deliberadamente mais pobre que a do painel.
    ///
    /// O fundo aqui e o wallpaper, nao uma superficie controlada: nenhum tom
    /// saturado sobrevive a um papel de parede de cor parecida (azul sobre azul
    /// some). `labelColor` e a unica cor com contraste garantido, porque o
    /// proprio macOS a inverte conforme o que esta atras da barra.
    ///
    /// Por isso a cor so e gasta nos dois estados que sao *evento* -- alguem
    /// travado esperando voce, e um turno que acabou de terminar. `working` nao
    /// precisa dela: o robo esta se mexendo, e movimento chama mais atencao que
    /// matiz. `idle` nao tem o que sinalizar.
    var barTint: NSColor {
        switch self {
        case .waiting: return .systemOrange
        case .done:    return .systemGreen
        case .working, .idle: return .labelColor
        }
    }
}

extension NSColor {
    /// Vermelho da porcentagem na menu bar.
    ///
    /// `systemRed` e um vermelho de superficie controlada. Em 12pt sobre
    /// wallpaper ele falha: o fundo tipico da barra e escuro e azulado, vizinho
    /// do vermelho em luminancia, e o numero vira um borrao escuro em vez de
    /// alerta -- justamente no estado que mais precisa ser lido.
    ///
    /// A matiz continua a mesma; o que muda e a luminancia, e ela muda de lado
    /// conforme a aparencia: coral no escuro, onde o numero precisa ser mais
    /// claro que o fundo, e carmim no claro, onde precisa ser mais escuro que
    /// ele. Resolvido por `dynamicProvider` porque o desenho do icone acontece
    /// sob a aparencia da menu bar, nao a da app.
    static let barCritical = NSColor(name: "barCritical") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.45, blue: 0.39, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.08, blue: 0.05, alpha: 1)
    }

    /// Fundo da etiqueta de limite critico.
    ///
    /// Pode ser saturada justamente por ser fundo: quem precisa de contraste
    /// contra o wallpaper e a etiqueta inteira, que e um bloco solido, e o texto
    /// branco por cima so precisa de contraste contra ela. E o que resolve o
    /// problema que `barCritical` so ameniza -- vermelho de texto continua
    /// dependendo de sorte com o papel de parede, e em corpo pequeno (as duas
    /// linhas do modo "ambas", 8,5pt) a sorte piora.
    static let barBadge = NSColor(name: "barBadge") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.86, green: 0.21, blue: 0.17, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.11, blue: 0.09, alpha: 1)
    }

    /// Porcentagem com dado velho (ver `Usage.isStale`).
    ///
    /// `secondaryLabelColor` e o gesto obvio e o errado aqui: ele esmaece por
    /// alpha, e o que fica atras do numero na menu bar e o wallpaper, nao uma
    /// superficie controlada. Sobre um fundo de luminancia parecida o composto
    /// simplesmente some -- medido com wallpaper azul medio, o "0%" ficou
    /// ilegivel enquanto os vizinhos da barra continuavam nitidos.
    ///
    /// Entao o esmaecido e feito com cor opaca: o numero fica visivelmente mais
    /// apagado que `labelColor` sem deixar o fundo atravessar. Como em
    /// `barCritical`, de que lado ele apaga depende da aparencia da barra.
    static let barStale = NSColor(name: "barStale") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.74, alpha: 1)
            : NSColor(white: 0.36, alpha: 1)
    }
}

enum Severity: String {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    /// Usado quando a API nao manda severity (ou o dado veio do disco).
    static func fromPct(_ pct: Double) -> Severity {
        if pct >= 85 { return .critical }
        if pct >= 60 { return .warning }
        return .normal
    }
}

struct Session: Identifiable {
    let id: String
    let project: String
    let state: SessionState
    let label: String
    let model: String
    let contextPct: Int?
    let updatedAt: Date
    /// Primeira mensagem do usuario -- a identidade da conversa. Nil enquanto o
    /// transcript nao foi lido, ou quando ela e so imagem/anexo.
    var title: String?
    /// Diretorio da sessao. E o que o clique abre, e o que casa a sessao com a
    /// janela do editor.
    let cwd: String
    /// De qual conta e esta sessao. Nao vem do arquivo: vem do config dir onde o
    /// arquivo estava, que e a unica coisa que os scripts nao teriam como errar.
    let accountID: String
    let accountTag: String
    /// Config dir da conta. O lock da janela do editor mora em `<config dir>/ide`,
    /// e cada conta escreve no seu -- procurar no dir errado acharia a janela de
    /// outra sessao.
    let configDir: URL

    /// O que aparece em destaque na linha. A conversa manda; a pasta e o
    /// fallback, porque duas sessoes na mesma pasta ficariam identicas.
    var headline: String { title ?? project }
}

struct Limit {
    var pct: Double
    var resetsAt: Date?
    var severity: Severity
    /// `resetsAt` foi deduzido do historico, nao lido de um campo. Vale um "~"
    /// na tela: a margem e de minutos (ver PlanHistory.inferReset), o suficiente
    /// para "faltam 2h" e de menos para "faltam 12min".
    var resetsAtIsEstimate = false

    /// A janela virou depois que o snapshot foi tirado: a porcentagem nao vale
    /// mais. Melhor dizer "reiniciou" que repetir um 85% que ja nao existe.
    ///
    /// Estimativa nao derruba porcentagem: errar dez minutos para menos apagaria
    /// da barra um numero que ainda vale. Quem estima so adianta o countdown.
    var rolledOver: Bool {
        guard let r = resetsAt, !resetsAtIsEstimate else { return false }
        return r <= Date()
    }
}

/// Creditos extra (cobrados) usados depois de estourar o limite do plano.
struct ExtraUsage {
    var pct: Double
    var used: Double
    var limit: Double
    var currency: String
    var severity: Severity
    var capReached: Bool
}

enum DataSource: String {
    case api, cache, planHistory, statusline, none

    var label: String {
        switch self {
        case .api:         return "API"
        case .cache:       return "cache do Claude Code"
        case .planHistory: return "app do Claude"
        case .statusline:  return "statusline"
        case .none:        return "sem dado"
        }
    }

    /// Se a fonte transporta o bloco de creditos extra. Distinguir "nao tem o
    /// campo no formato" de "tem o campo e veio vazio" e o que impede herdar um
    /// extra_usage que a API ja parou de mandar porque ele foi desativado.
    var carriesExtra: Bool { self == .api || self == .cache }
}

struct Usage {
    var fiveHour: Limit?
    var sevenDay: Limit?
    var extra: ExtraUsage?
    var source: DataSource = .none
    var at: Date?

    var isStale: Bool {
        guard let at = at else { return true }
        return Date().timeIntervalSince(at) > K.dataStale
    }
}

/// Por que a API nao esta sendo usada agora. Vira texto no painel -- um app que
/// silenciosamente para de atualizar e pior que um que explica o porque.
enum APIStatus {
    case ok
    case noToken
    case tokenExpired
    case rateLimited(until: Date)
    case failed(String)

    var note: String? {
        switch self {
        case .ok: return nil
        case .noToken: return "Token ilegível — mostrando o cache do Claude Code."
        case .tokenExpired: return "Token expirado; o Claude Code renova em breve."
        case .rateLimited(let until):
            let m = max(1, Int(until.timeIntervalSinceNow / 60))
            return "API limitou (429) — nova tentativa em ~\(m)min."
        case .failed(let why): return "API indisponível: \(why)"
        }
    }
}

// MARK: - Parsing

private enum Parse {
    /// `resets_at` chega em dois formatos: epoch em segundos (statusline) e
    /// string ISO-8601 com microssegundos (API, ex. "2026-07-30T14:30:00.380291+00:00").
    static func date(_ any: Any?) -> Date? {
        if let n = any as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        guard var s = any as? String, !s.isEmpty else { return nil }

        // ISO8601DateFormatter e exigente com fracao de segundo de 6 digitos.
        // Precisao sub-segundo nao importa para um countdown, entao remove.
        if let dot = s.firstIndex(of: ".") {
            let tail = s[s.index(after: dot)...]
            if let tz = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
                s.removeSubrange(dot..<tz)
            } else {
                s.removeSubrange(dot..<s.endIndex)
            }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// `utilization` da API e 0-100 (confirmado empiricamente: five_hour 100.0,
    /// seven_day 38.0). Nao normalizar: multiplicar um 0.5% legitimo por 100
    /// seria pior que o problema que a "defesa" resolveria.
    static func pct(_ any: Any?) -> Double? {
        guard let n = any as? Double, n.isFinite else { return nil }
        return min(max(n, 0), 100)
    }
}

// MARK: - Contas

/// Uma conta do Claude Code nesta maquina.
///
/// O Claude Code separa conta por **config dir**: a padrao usa `~/.claude`, com
/// o `~/.claude.json` ao lado (fora dela); qualquer outra vive inteira dentro do
/// `CLAUDE_CONFIG_DIR` apontado -- o `.claude.json` dela, `projects/`, `ide/` e o
/// `claude-bar/` que os scripts escrevem. E o que faz duas contas caberem neste
/// app sem nenhuma heuristica: a conta de um dado e o diretorio de onde ele veio,
/// nunca um palpite sobre qual sessao o produziu.
struct Account: Identifiable, Equatable {
    /// `accountUuid` do `oauthAccount`. Sem login feito naquele config dir nao ha
    /// uuid, e o caminho serve de identidade: nao colide com uuid nenhum e a
    /// conta continua aparecendo, porque sessao e custo dela ja estao em disco.
    let id: String

    /// A letra que aparece no painel e na menu bar. "P" e sempre a conta padrao
    /// -- a que este app ja rastreava quando so existia uma.
    let tag: String

    /// Email da conta. Cai para o nome do diretorio quando nao da para ler.
    let name: String

    /// `organizationUuid`. E por ele que as amostras do historico do app nativo,
    /// carimbadas por org, encontram a conta certa.
    let org: String?

    let configDir: URL
    let claudeJSON: URL
    let isDefault: Bool

    var stateDir: URL { configDir.appendingPathComponent("claude-bar") }
    var sessionsDir: URL { stateDir.appendingPathComponent("sessions") }
    var usageFile: URL { stateDir.appendingPathComponent("usage.json") }
    var projectsDir: URL { configDir.appendingPathComponent("projects") }
}

enum Accounts {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Conta + snapshot do `.claude.json` de cada config dir, com um **unico**
    /// parse por arquivo: o mesmo JSON carrega a identidade da conta e o
    /// `cachedUsageUtilization`, e sao ~60KB que o Claude Code reescreve o tempo
    /// todo -- parsear duas vezes por tick seria pagar dobrado pelo mesmo byte.
    /// `tags` e `names` sao os apelidos que o dono da maquina deu, por id da
    /// conta (ver Settings.setLabel). Chegam como parametro em vez de saírem do
    /// Settings aqui dentro porque esta varredura roda na fila de IO, e ler
    /// estado observavel fora da main e o tipo de atalho que so quebra em
    /// producao.
    static func scan(tags: [String: String] = [:],
                     names: [String: String] = [:]) -> [(account: Account, snapshot: ClaudeConfig.Snapshot)] {
        var out: [(account: Account, snapshot: ClaudeConfig.Snapshot)] = []
        var extras = 0
        var used = Set<String>()

        for (index, dir) in configDirs().enumerated() {
            let isDefault = index == 0
            // A unica assimetria do formato: a conta padrao guarda o .claude.json
            // ao lado do config dir, nao dentro dele.
            let json = isDefault ? home.appendingPathComponent(".claude.json")
                                 : dir.appendingPathComponent(".claude.json")
            let snapshot = ClaudeConfig.read(at: json)

            // O uuid e a identidade preferida porque sobrevive a mover o config
            // dir de lugar. A mesma conta logada em dois config dirs repetiria o
            // uuid, e duas entradas com o mesmo id embaralhariam fontes, custo e
            // apelidos -- nesse caso o caminho desempata.
            var id = snapshot.identity?.uuid ?? dir.path
            if !used.insert(id).inserted { id = dir.path; used.insert(id) }

            let tag: String
            if isDefault {
                tag = "P"
            } else {
                extras += 1
                tag = extras == 1 ? "E" : "E\(extras)"
            }

            out.append((Account(id: id,
                                tag: tags[id] ?? tag,
                                name: names[id] ?? snapshot.identity?.email ?? dir.lastPathComponent,
                                org: snapshot.identity?.org,
                                configDir: dir,
                                claudeJSON: json,
                                isDefault: isDefault),
                        snapshot))
        }
        return out
    }

    /// Os config dirs, a padrao sempre primeiro.
    ///
    /// `CLAUDE_CONFIG_DIR` aceita qualquer caminho, mas o app nao tem como ler o
    /// ambiente de um shell que ele nao abriu -- entao a busca e por convencao:
    /// irmaos de `~/.claude` que comecem com `.claude-` e tenham um `.claude.json`
    /// dentro. E o formato que se usa na pratica (`~/.claude-empresa`), e o custo
    /// de errar e assimetrico: um config dir fora do $HOME simplesmente nao
    /// aparece no painel, enquanto adivinhar mais do que isso poria numero de uma
    /// conta debaixo do nome de outra.
    ///
    /// Uma copia de backup com `.claude.json` dentro entraria na lista -- e por
    /// isso que cada cartao mostra o email da conta, e nao so a letra.
    private static func configDirs() -> [URL] {
        let fm = FileManager.default
        var dirs = [home.appendingPathComponent(".claude")]

        let entries = (try? fm.contentsOfDirectory(at: home,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.lastPathComponent.hasPrefix(".claude-"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fm.fileExists(atPath: url.appendingPathComponent(".claude.json").path)
            else { continue }
            dirs.append(url)
        }
        return dirs
    }
}

// MARK: - Cache do Claude Code (<config dir>/.claude.json)

/// Quem e a conta daquele config dir. Sai do bloco `oauthAccount`, que o Claude
/// Code mantem atualizado a cada refresh de perfil.
struct AccountIdentity {
    let uuid: String
    let email: String
    let org: String?
}

/// O `.claude.json` de uma conta, lido de uma vez so.
enum ClaudeConfig {

    struct Snapshot {
        var identity: AccountIdentity?
        var usage: UsageCache.Result = .noFile
    }

    /// Le identidade e `cachedUsageUtilization` do `.claude.json`.
    ///
    /// O arquivo tem ~60KB e e reescrito com frequencia pelo proprio Claude Code.
    /// Ler e parsear a cada tick e barato, mas TEM que ser fora da main thread e
    /// TEM que tolerar falha: pegar uma escrita pela metade devolve `.unreadable`,
    /// e quem chama mantem o ultimo valor bom em vez de piscar "sem dado".
    static func read(at url: URL) -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(identity: nil, usage: .noFile)
        }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Snapshot(identity: nil, usage: .unreadable) }

        return Snapshot(identity: identity(root), usage: UsageCache.read(root))
    }

    private static func identity(_ root: [String: Any]) -> AccountIdentity? {
        guard let oauth = root["oauthAccount"] as? [String: Any],
              let uuid = oauth["accountUuid"] as? String, !uuid.isEmpty
        else { return nil }
        let org = oauth["organizationUuid"] as? String
        return AccountIdentity(uuid: uuid,
                               email: (oauth["emailAddress"] as? String) ?? uuid,
                               org: (org?.isEmpty == false) ? org : nil)
    }
}

enum UsageCache {

    enum Result {
        case success(Usage)
        case noFile
        case noUsageKey
        case unreadable
    }

    /// Extrai `cachedUsageUtilization` de um `.claude.json` ja parseado.
    static func read(_ root: [String: Any]) -> Result {
        guard let cache = root[K.cacheKey] as? [String: Any],
              let util = cache["utilization"] as? [String: Any]
        else { return .noUsageKey }

        var u = decode(util)
        u.source = .cache
        // fetchedAtMs e quando o Claude Code buscou da API -- nao quando o arquivo
        // foi tocado. E esse o carimbo honesto para a idade mostrada no painel.
        if let ms = cache["fetchedAtMs"] as? Double, ms > 0 {
            u.at = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        } else {
            u.at = Date()
        }
        guard u.fiveHour != nil || u.sevenDay != nil else { return .noUsageKey }
        return .success(u)
    }

    /// Monta o Usage a partir do bloco `utilization` -- que e a resposta crua de
    /// /api/oauth/usage. Serve para as duas fontes justamente por isso: o que o
    /// Claude Code guarda em disco e byte a byte o que a API devolve.
    /// Os objetos `five_hour` / `seven_day` sao a fonte estavel; `limits[]` so
    /// enriquece com severity quando existe.
    static func decode(_ obj: [String: Any]) -> Usage {
        var u = Usage()

        let severities = severityByGroup(obj["limits"])

        if let d = obj["five_hour"] as? [String: Any], let p = Parse.pct(d["utilization"]) {
            u.fiveHour = Limit(pct: p,
                               resetsAt: Parse.date(d["resets_at"]),
                               severity: severities["session"] ?? .fromPct(p))
        }
        if let d = obj["seven_day"] as? [String: Any], let p = Parse.pct(d["utilization"]) {
            u.sevenDay = Limit(pct: p,
                               resetsAt: Parse.date(d["resets_at"]),
                               severity: severities["weekly"] ?? .fromPct(p))
        }

        // extra_usage: creditos cobrados apos estourar o plano. used_credits e
        // monthly_limit vem em unidade minima da moeda (decimal_places diz quanto dividir).
        if let e = obj["extra_usage"] as? [String: Any],
           (e["is_enabled"] as? Bool) == true,
           let p = Parse.pct(e["utilization"]) {
            let dp = (e["decimal_places"] as? Double) ?? 2
            let div = pow(10.0, dp)
            let used = ((e["used_credits"] as? Double) ?? 0) / div
            let limit = ((e["monthly_limit"] as? Double) ?? 0) / div
            let sev = (obj["spend"] as? [String: Any])
                .flatMap { Severity(rawValue: ($0["severity"] as? String) ?? "") }
            u.extra = ExtraUsage(pct: p,
                                 used: used,
                                 limit: limit,
                                 currency: (e["currency"] as? String) ?? "",
                                 severity: sev ?? .fromPct(p),
                                 capReached: (e["spend_limit_reached"] as? Bool) ?? false)
        }
        return u
    }

    private static func severityByGroup(_ any: Any?) -> [String: Severity] {
        guard let arr = any as? [[String: Any]] else { return [:] }
        var out: [String: Severity] = [:]
        for row in arr {
            if let g = row["group"] as? String,
               let s = row["severity"] as? String,
               let sev = Severity(rawValue: s) {
                out[g] = sev
            }
        }
        return out
    }
}

// MARK: - Historico do app nativo (~/Library/Application Support/Claude)

/// O app do Claude poleia `/api/organizations/<org>/usage` sozinho a cada 300s e
/// grava cada amostra num historico de 30 dias. Ler esse arquivo custa zero
/// requisicao e zero credencial: o trabalho ja foi feito por quem tinha que
/// fazer.
///
/// Duas limitacoes, ambas de formato e nao de bug:
///   - so porcentagem. Nao ha `resets_at` -- quem publica herda a agenda de
///     outro snapshot, e na falta dela deduz a da janela de 5h da propria serie
///     (ver inferReset).
///   - so anda com o app aberto. Fechado, ou maquina dormindo, a ultima amostra
///     envelhece e perde para as outras fontes na comparacao por carimbo.
private enum PlanHistory {

    /// Chaves do formato v2. `so`/`sn` sao limites por modelo, que so aparecem em
    /// conta que os tenha; `xu` e a porcentagem de creditos extra, sem o
    /// suficiente (usado, teto, moeda) para montar um ExtraUsage honesto.
    private static let fiveHourKey = "fh"
    private static let sevenDayKey = "sd"

    /// Duracao da janela curta. Nao sai do arquivo -- e a regra do plano.
    private static let window: TimeInterval = 5 * 3600

    /// Buraco na serie que invalida a deducao. O app amostra a cada 300s; um vao
    /// maior que este significa app fechado ou maquina dormindo, e ai uma janela
    /// pode ter virado inteira sem ninguem ver -- inclusive a que estamos
    /// tentando datar.
    private static let maxGap: TimeInterval = 30 * 60

    /// Uma serie por organizacao, mais a serie sem carimbo.
    struct Series {
        var byOrg: [String: Usage] = [:]
        /// Serie inteira, e so quando **nenhuma** amostra traz `org` -- formato
        /// antigo, de quando o app nativo nao carimbava. Vale so para a conta
        /// padrao: numa maquina de uma conta so nao ha ambiguidade nenhuma, e
        /// numa de duas o arquivo ja vem carimbado.
        var legacy: Usage?
    }

    /// Le o arquivo uma vez e separa as amostras por organizacao.
    ///
    /// O filtro por org nao e zelo: o app nativo poleia a conta em que *ele* esta
    /// logado, e cada amostra diz de qual org ela e. Sem separar, a serie de uma
    /// conta apareceria debaixo do nome da outra -- e numero errado com cara de
    /// fresco e o pior estado possivel deste painel, pior que ficar sem fonte.
    static func read(at url: URL) -> Series {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]]
        else { return Series() }

        let valid = samples.filter { stamp($0) > 0 }
        var grouped: [String: [[String: Any]]] = [:]
        for sample in valid {
            guard let org = sample["org"] as? String, !org.isEmpty else { continue }
            grouped[org, default: []].append(sample)
        }

        var series = Series()
        if grouped.isEmpty {
            series.legacy = usage(from: valid)
            return series
        }
        for (org, rows) in grouped {
            let u = usage(from: rows)
            if u.at != nil { series.byOrg[org] = u }
        }
        return series
    }

    /// Monta o Usage de uma serie ja separada por conta.
    private static func usage(from samples: [[String: Any]]) -> Usage {
        // Ordenado, e nao max(by:): na pratica o arquivo e cronologico, mas nada
        // no formato promete isso -- uma amostra fora de ordem mostraria numero
        // velho como se fosse o atual, e quebraria a leitura da serie abaixo.
        let ordered = samples.sorted { stamp($0) < stamp($1) }
        guard let newest = ordered.last else { return Usage() }

        // v2 aninha as porcentagens em `u`; v1 deixa na raiz da amostra.
        let vals = (newest["u"] as? [String: Any]) ?? newest

        var u = Usage()
        u.source = .planHistory
        u.at = Date(timeIntervalSince1970: stamp(newest) / 1000)
        if let p = Parse.pct(vals[fiveHourKey]) {
            let guess = inferReset(ordered)
            u.fiveHour = Limit(pct: p, resetsAt: guess, severity: .fromPct(p),
                               resetsAtIsEstimate: guess != nil)
        }
        if let p = Parse.pct(vals[sevenDayKey]) {
            // A janela de 7 dias fica de fora de proposito: ela quase nunca
            // zera nesta serie, e sem uma borda observada a mesma conta viraria
            // extrapolacao de dias a partir de nada.
            u.sevenDay = Limit(pct: p, resetsAt: nil, severity: .fromPct(p))
        }
        // Sem nenhum dos dois o carimbo sozinho nao vale nada -- e venceria a
        // comparacao por frescor sem ter numero para mostrar.
        guard u.fiveHour != nil || u.sevenDay != nil else { return Usage() }
        return u
    }

    /// Deduz o fim da janela de 5h a partir da propria serie.
    ///
    /// A janela nao corre em grade fixa: ela ancora no **primeiro uso** depois de
    /// zerar e morre 5h depois. Isso e visivel aqui -- a corrida atual de
    /// amostras com uso > 0 comeca justamente naquele primeiro uso, entao o
    /// reset e o inicio da corrida mais 5h.
    ///
    /// Medido contra os 8 ultimos resets desta serie e contra o
    /// `five_hour_resets_at` que a statusline gravou em 31/07: erro de -10 a
    /// +2 min, mediana -7. O sinal e sistematico e tem causa conhecida -- com
    /// amostragem de 300s o primeiro uso cai em algum ponto *antes* da amostra
    /// que o revela, entao a estimativa adianta. Adiantar e o lado certo de
    /// errar: o countdown vence antes da janela, nunca depois.
    ///
    /// Devolve nil em vez de chutar quando a serie nao sustenta a conta.
    private static func inferReset(_ ordered: [[String: Any]]) -> Date? {
        guard let last = ordered.last, (pct(last) ?? 0) > 0 else { return nil }

        // Anda para tras enquanto houver uso, ate achar a amostra zerada que
        // antecede a corrida. Amostra sem `fh` nao e zero: e ausencia de dado, e
        // seguir por cima dela dataria a janela errada.
        var i = ordered.count - 1
        while i >= 0 {
            guard let v = pct(ordered[i]) else { return nil }
            if v == 0 { break }
            i -= 1
        }
        // A corrida encosta no comeco do arquivo: o inicio real ficou fora da
        // janela de 30 dias que o app guarda, e nao ha o que datar.
        guard i >= 0, i + 1 < ordered.count else { return nil }

        let start = Date(timeIntervalSince1970: stamp(ordered[i + 1]) / 1000)

        // Serie continua do inicio da corrida ate agora, senao a corrida pode
        // estar costurando duas janelas com o app fechado no meio.
        for j in i..<(ordered.count - 1) {
            let gap = (stamp(ordered[j + 1]) - stamp(ordered[j])) / 1000
            guard gap <= maxGap else { return nil }
        }

        let reset = start.addingTimeInterval(window)
        // Ja passou da hora e a serie nao mostrou o zero: quem esta velha e a
        // ultima amostra, nao a janela. Sem data e melhor que data vencida.
        guard reset > Date() else { return nil }
        return reset
    }

    /// Porcentagem da janela de 5h de uma amostra, nos dois formatos.
    private static func pct(_ sample: [String: Any]) -> Double? {
        Parse.pct(((sample["u"] as? [String: Any]) ?? sample)[fiveHourKey])
    }

    /// Epoch em milissegundos.
    private static func stamp(_ sample: [String: Any]) -> Double {
        (sample["t"] as? Double) ?? 0
    }
}

// MARK: - Token

private enum Token {

    struct Value {
        let bearer: String
        let expiresAt: Date?
        var isExpired: Bool {
            guard let e = expiresAt else { return false }
            return e <= Date()
        }
    }

    /// Le o token OAuth delegando para /usr/bin/security, e nao para
    /// SecItemCopyMatching.
    ///
    /// Essa escolha e a diferenca entre pedir autorizacao para sempre e nunca
    /// pedir. O Claude Code nao usa a API SecItem: ele shella para a CLI
    /// `security`. Logo, a ACL do item "Claude Code-credentials" confia no
    /// binario /usr/bin/security -- e so nele. Um app proprio chamando
    /// SecItemCopyMatching e um requerente desconhecido: o macOS abre o dialogo
    /// "Permitir". E "Sempre Permitir" nao resolve, porque a ACL e refeita a cada
    /// refresh de token (ou seja, a cada reboot o prompt volta).
    ///
    /// Chamando o mesmo binario que criou o item, quem o Keychain avalia e o
    /// /usr/bin/security. Passa direto, sem dialogo, sem gravar nada.
    static func read() -> Value? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", K.keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // stdin fechado: se algum dia o `security` quiser interagir, ele falha
        // rapido em vez de pendurar o processo esperando digitacao.
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return nil }

        // Ler antes de esperar: o pipe tem buffer limitado e um waitUntilExit
        // primeiro poderia travar se a saida enchesse. Aqui a saida e pequena,
        // mas a ordem certa custa nada.
        let data = out.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(K.securityTimeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let bearer = oauth["accessToken"] as? String, !bearer.isEmpty
        else { return nil }

        // expiresAt vem em milissegundos (confirmado: 1785423513660).
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double, ms > 0 {
            expires = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        }
        return Value(bearer: bearer, expiresAt: expires)
    }
}

// MARK: - API

private enum UsageAPI {

    enum Result {
        case success(Usage)
        case rateLimited
        case unauthorized
        case failure(String)
    }

    static func fetch(token: String, completion: @escaping (Result) -> Void) {
        var req = URLRequest(url: K.usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(K.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure("resposta inesperada"))
                return
            }
            switch http.statusCode {
            case 200:
                guard let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else {
                    completion(.failure("JSON inválido"))
                    return
                }
                var u = UsageCache.decode(obj)
                u.source = .api
                u.at = Date()
                guard u.fiveHour != nil || u.sevenDay != nil else {
                    completion(.failure("resposta sem limites"))
                    return
                }
                completion(.success(u))
            case 429:
                completion(.rateLimited)
            case 401, 403:
                completion(.unauthorized)
            default:
                completion(.failure("HTTP \(http.statusCode)"))
            }
        }.resume()
    }
}

// MARK: - Store

/// Uma linha de texto da menu bar, ja resolvida: o que escrever, em que cor, e
/// se ela vai dentro de uma etiqueta (e de que cor e o fundo dela).
struct BarLine {
    let text: String
    let color: NSColor
    /// Fundo da etiqueta. Nil = texto solto sobre o wallpaper.
    let badge: NSColor?
}

/// Uma conta com o uso ja resolvido -- e uma destas por cartao do painel.
struct AccountUsage: Identifiable {
    let account: Account
    var usage: Usage
    var id: String { account.id }
}

final class Store: ObservableObject {
    @Published var sessions: [Session] = []

    /// Uma entrada por conta, a padrao primeiro. Com uma conta so -- o caso de
    /// quem instalou num config dir unico -- e uma lista de um elemento, e o
    /// painel volta a ser exatamente o de antes.
    @Published var accounts: [AccountUsage] = []

    @Published var apiStatus: APIStatus = .ok

    @Published var cost = CostStats()

    /// Objeto separado (nao um @Published daqui) para a animacao do icone nao
    /// arrastar o painel inteiro para um redesenho a cada quadro.
    let pulse = Pulse()

    private let scanner = CostScanner()
    private var scanning = false
    /// Vive na fila de IO junto com readSessions(), que e quem o consulta.
    private let titles = SessionTitles()

    /// Historico do app nativo. Se ele nao estiver instalado o arquivo nao
    /// existe, a leitura devolve serie vazia e a fonte simplesmente nao entra
    /// na disputa -- nao ha nada a tratar como erro.
    private let planHistoryJSON = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    private var timer: Timer?
    private let io = DispatchQueue(label: "local.claudebar.io", qos: .utility)
    private let costQueue = DispatchQueue(label: "local.claudebar.cost", qos: .utility)

    /// As quatro fontes ficam separadas para poder escolher a mais fresca a cada
    /// tick, em vez de uma sobrescrever a outra -- e agora ha um conjunto destes
    /// por conta, indexado pelo id dela. Misturar as fontes de duas contas num
    /// balde so faria a comparacao por frescor escolher entre numeros de donos
    /// diferentes, que e o unico jeito de este painel mentir feio.
    private struct Sources {
        var api = Usage()
        var cache = Usage()
        var history = Usage()
        var file = Usage()
    }
    private var sources: [String: Sources] = [:]

    /// As contas achadas na ultima varredura, na ordem em que aparecem.
    private var known: [Account] = []

    private var nextAPIFetch = Date.distantPast
    private var backoff = K.apiInterval
    private var fetching = false
    private var lastPanelFetch = Date.distantPast

    init() {
        reload()
        start()
    }

    deinit { timer?.invalidate() }

    /// Idempotente: invalida o timer anterior antes de criar outro. Sem isso,
    /// cada chamada deixava um timer orfao vivo no run loop.
    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: K.fileInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common: no modo .default o timer congela enquanto o popover esta em
        // tracking loop -- exatamente quando voce esta olhando para ele.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    var headline: SessionState {
        sessions.map(\.state).min(by: { $0.priority < $1.priority }) ?? .idle
    }

    /// A conta que a menu bar representa: a da sessao que manda no icone.
    ///
    /// Nao e "a mais recente" nem "a que esta pior" -- e a mesma sessao que o robo
    /// esta descrevendo, porque `sessions` ja vem ordenada por prioridade de
    /// estado e, dentro dela, por recencia. Icone e numero falando de sessoes
    /// diferentes deixaria a barra dizendo que a conta E esta travada enquanto
    /// mostra a porcentagem da P.
    ///
    /// Sem sessao nenhuma sobra a primeira conta, que e sempre a padrao.
    private var active: AccountUsage? {
        if let id = sessions.first?.accountID,
           let hit = accounts.first(where: { $0.id == id }) { return hit }
        return accounts.first
    }

    var activeAccount: Account? { active?.account }

    /// O uso que a barra mostra. Campo derivado, e nao mais um @Published: manter
    /// uma copia do uso da conta ativa era mais um estado para dessincronizar.
    var usage: Usage { active?.usage ?? Usage() }

    var multiAccount: Bool { accounts.count > 1 }

    /// Recorte de custo com as contas ja nomeadas. O acumulado e indexado por id
    /// (a letra muda quando o dono da maquina renomeia a conta), entao a traducao
    /// acontece aqui, uma vez, na hora de montar a tela.
    func costReport(days: Int) -> CostReport {
        cost.report(days: days,
                    accountLabels: Dictionary(accounts.map { ($0.id, $0.account.tag) },
                                              uniquingKeysWith: { first, _ in first }))
    }

    /// A conta que a barra mostra quando a preferencia nao e "ambas".
    ///
    /// Fixar uma conta que sumiu nao trava a barra em branco: cai para a ativa,
    /// que e o comportamento padrao.
    private var barEntry: AccountUsage? {
        let choice = Settings.shared.barAccount
        if choice == Settings.barAccountActive || choice == Settings.barAccountBoth { return active }
        return accounts.first(where: { $0.id == choice }) ?? active
    }

    /// O que vai escrito ao lado do robo: uma linha, ou duas no modo "ambas".
    ///
    /// Lista, e nao String, porque a menu bar do macOS nao quebra linha sozinha
    /// -- quem empilha e o desenho do icone (ver MenuIcon.image), e ele precisa
    /// da cor de cada linha separada: duas contas tem severidades diferentes, e
    /// pintar as duas pela pior esconderia justamente qual delas esta doendo.
    var menuLines: [BarLine] {
        guard Settings.shared.barMode != .iconOnly else { return [] }
        let report = costReport(days: 1)

        // "Ambas" so faz sentido havendo duas: com uma conta o modo se comporta
        // como qualquer outro, sem virar uma linha solitaria em corpo menor.
        if Settings.shared.barAccount == Settings.barAccountBoth, multiAccount {
            return accounts.compactMap { line(for: $0, report: report, showTag: true) }
        }
        guard let entry = barEntry else { return [] }
        return [line(for: entry, report: report, showTag: multiAccount)].compactMap { $0 }
    }

    /// Uma linha da barra. Nil quando nao sobrou nada para escrever -- limite
    /// virado sem countdown, por exemplo -- para o robo nao ficar com um espaco
    /// vazio do lado.
    private func line(for entry: AccountUsage, report: CostReport, showTag: Bool) -> BarLine? {
        let usage = entry.usage
        var text: String
        switch Settings.shared.barMode {
        case .iconOnly:
            return nil
        case .percent:
            text = percentText(usage)
        case .resetTimer:
            text = resetText(usage)
        case .percentAndReset:
            // Cada metade ja sabe sumir sozinha -- limite virado apaga a
            // porcentagem, ausencia de resets_at apaga o relogio. O separador
            // so entra quando as duas sobreviveram; montar a string com ele
            // fixo deixaria "| 1h34" ou "54% |" na barra, que le como bug.
            text = [percentText(usage), resetText(usage)]
                .filter { !$0.isEmpty }.joined(separator: " | ")
        case .costToday:
            // Com mais de uma conta o custo tambem e por conta: a letra na frente
            // promete que aquele numero e daquele login, e um total somado ali
            // desmentiria a promessa. Com uma conta so, e o total de sempre.
            text = Money.short(multiAccount
                ? (report.byAccount.first(where: { $0.id == entry.id })?.bucket.cost ?? 0)
                : report.total.cost)
        }
        guard !text.isEmpty else { return nil }
        if showTag { text = "\(entry.account.tag) \(text)" }
        let look = emphasis(for: usage)
        return BarLine(text: text, color: look.color, badge: look.badge)
    }

    private func percentText(_ usage: Usage) -> String {
        guard let five = usage.fiveHour, !five.rolledOver else { return "" }
        return "\(Int(five.pct.rounded()))%"
    }

    /// Contagem regressiva ate a janela de 5h virar. Minutos abaixo de uma hora,
    /// senao a barra ficaria mostrando "0h" por 59 minutos.
    ///
    /// Com uso zerado nao ha countdown porque nao ha janela: ela ancora no
    /// primeiro uso e morre 5h depois, entao antes dele nao existe hora nenhuma
    /// para contar. O campo diz "ao usar" em vez de sumir -- um campo que
    /// desaparece le como dado faltando, e foi exatamente assim que a barra
    /// pareceu quebrada: "0%" sozinho, sem nada do lado, indistinguivel de um bug.
    private func resetText(_ usage: Usage) -> String {
        if let five = usage.fiveHour, five.pct == 0, five.resetsAt == nil { return "ao usar" }
        guard let five = usage.fiveHour, let at = five.resetsAt else { return "" }
        let secs = at.timeIntervalSinceNow
        guard secs > 0 else { return "0m" }
        // Data deduzida do historico erra minutos (ver PlanHistory.inferReset).
        // O til custa uns pontos de largura e evita a barra afirmar "12m" quando
        // o que ela sabe e "por volta de".
        let tilde = five.resetsAtIsEstimate ? "~" : ""
        if secs < 3600 { return "\(tilde)\(Int(secs / 60))m" }
        return "\(tilde)\(Int(secs / 3600))h\(String(format: "%02d", Int(secs.truncatingRemainder(dividingBy: 3600) / 60)))"
    }

    /// Como aquela linha se apresenta na barra. Padrao e `labelColor` -- um numero
    /// tranquilo tem que se comportar como qualquer outro item da barra; o realce
    /// fica reservado para quando o limite esta perto de doer.
    ///
    /// Sessao esperando decisao nao entra aqui: quem sinaliza isso e o robo,
    /// que fica laranja e pisca. Realcar tambem o numero custaria o unico dado
    /// que ele carrega -- a porcentagem passaria a mentir sobre a severidade do
    /// uso justamente quando ela esta alta.
    ///
    /// Dado velho nunca ganha realce: um alerta sobre numero congelado alarma
    /// sobre um estado que talvez nem exista mais.
    private func emphasis(for usage: Usage) -> (color: NSColor, badge: NSColor?) {
        if usage.isStale { return (.barStale, nil) }
        guard let five = usage.fiveHour, !five.rolledOver else { return (.labelColor, nil) }

        switch Settings.shared.barEmphasis {
        case .plain:
            return (.labelColor, nil)
        case .tint:
            switch five.severity {
            case .critical: return (.barCritical, nil)
            case .warning:  return (.systemOrange, nil)
            case .normal:   return (.labelColor, nil)
            }
        case .badge:
            // Etiqueta so no critico. Duas cores solidas na barra ao mesmo tempo
            // competiriam entre si, e o laranja de texto ja e legivel -- ele tem
            // luminancia alta, que e exatamente o que falta ao vermelho.
            switch five.severity {
            case .critical: return (.white, .barBadge)
            case .warning:  return (.systemOrange, nil)
            case .normal:   return (.labelColor, nil)
            }
        }
    }

    private func tick() {
        reload()
        maybeFetchAPI()
        scanCost()
    }

    /// Fila propria, nao a de IO: a primeira varredura le centenas de MB de
    /// transcript, e numa fila serial compartilhada ela seguraria a atualizacao
    /// das sessoes por segundos. Um scan por vez -- dois em paralelo leriam o
    /// mesmo trecho duas vezes.
    private func scanCost() {
        guard !scanning else { return }
        // Sem conta descoberta ainda nao ha o que varrer: o primeiro reload()
        // chega em milissegundos e o scan entra no tick seguinte.
        let roots = known.map { (id: $0.id, url: $0.projectsDir) }
        guard !roots.isEmpty else { return }
        scanning = true
        costQueue.async { [weak self] in
            guard let self = self else { return }
            let changed = self.scanner.scan(roots: roots)
            let snapshot = self.scanner.stats
            DispatchQueue.main.async {
                self.scanning = false
                if changed { self.cost = snapshot }
            }
        }
    }

    // MARK: Disco

    func reload() {
        // Lidos aqui, na main, e levados para a fila de IO como valor.
        let tags = Settings.shared.accountTags
        let names = Settings.shared.accountNames
        io.async { [weak self] in
            guard let self = self else { return }
            // Uma varredura de contas por tick, e dela sai tudo o que e por conta:
            // qual .claude.json ler, onde estao as sessoes, qual org filtrar no
            // historico. Listar o $HOME e parsear os .claude.json custa o mesmo
            // que a leitura unica que havia antes.
            let scanned = Accounts.scan(tags: tags, names: names)
            let accounts = scanned.map(\.account)
            let loaded = self.readSessions(accounts)
            var files: [String: Usage] = [:]
            for account in accounts { files[account.id] = self.readUsageFile(account) }
            let history = PlanHistory.read(at: self.planHistoryJSON)

            DispatchQueue.main.async {
                self.sessions = loaded
                self.pulse.sync(with: self.headline)
                self.apply(scanned, files: files, history: history)
                self.publishUsage()
            }
        }
    }

    /// Guarda o que cada conta trouxe desta volta.
    ///
    /// Regra que vale para as tres fontes de disco: leitura que falhou nao apaga
    /// numero bom da tela. Aqui o caso comum nem e corrupcao -- e o app nativo nao
    /// instalado, ou um config dir sem login -- e nesse caso o snapshot fica
    /// vazio para sempre, sem custo nenhum.
    private func apply(_ scanned: [(account: Account, snapshot: ClaudeConfig.Snapshot)],
                       files: [String: Usage],
                       history: PlanHistory.Series) {
        known = scanned.map(\.account)

        // Conta que sumiu (config dir apagado, login desfeito) leva junto o que
        // estava guardado dela: sem isso o painel seguraria um numero orfao, de
        // uma conta que nao existe mais, para sempre.
        let ids = Set(known.map(\.id))
        sources = sources.filter { ids.contains($0.key) }

        for (account, snapshot) in scanned {
            var s = sources[account.id] ?? Sources()
            if case .success(let u) = snapshot.usage { s.cache = u }
            if let u = historyUsage(for: account, in: history), u.at != nil { s.history = u }
            s.file = files[account.id] ?? Usage()
            sources[account.id] = s
        }
    }

    /// A serie do app nativo que pertence a esta conta.
    ///
    /// Sem org conhecida a conta nao herda serie nenhuma. A excecao e a conta
    /// padrao com um arquivo do formato antigo, sem carimbo de org: ali nao ha
    /// outra conta com quem confundir. Ficar sem a fonte 2 custa frescor -- pegar
    /// a serie da conta errada custaria a verdade.
    private func historyUsage(for account: Account, in series: PlanHistory.Series) -> Usage? {
        if let org = account.org, let u = series.byOrg[org] { return u }
        if account.isDefault, series.byOrg.isEmpty { return series.legacy }
        return nil
    }

    private func readSessions(_ accounts: [Account]) -> [Session] {
        var loaded: [Session] = []
        let fm = FileManager.default

        for account in accounts {
            let files = (try? fm.contentsOfDirectory(at: account.sessionsDir,
                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }

                // hook.py grava updated_at; statusline.py grava seen_at. Usar o maior:
                // uma sessao viva que renderiza a statusline mas nao bate em Stop ha
                // 6h tem updated_at velho e seria descartada sem isso.
                let updatedAt = (obj["updated_at"] as? Double) ?? 0
                let seenAt = (obj["seen_at"] as? Double) ?? 0
                let stamp = max(updatedAt, seenAt)
                guard stamp > 0 else { continue }
                let updated = Date(timeIntervalSince1970: stamp)
                guard Date().timeIntervalSince(updated) < K.staleAfter else { continue }

                let id = obj["session_id"] as? String ?? file.lastPathComponent
                loaded.append(Session(
                    id: id,
                    project: obj["project"] as? String ?? "—",
                    state: SessionState(rawValue: obj["state"] as? String ?? "idle") ?? .idle,
                    label: obj["label"] as? String ?? "",
                    model: obj["model"] as? String ?? "",
                    contextPct: obj["context_pct"] as? Int,
                    updatedAt: updated,
                    // O transcript e procurado so no projects/ desta conta: e
                    // onde ele esta, e limita a busca a uma arvore em vez de
                    // todas.
                    title: titles.title(for: id, in: account.projectsDir),
                    cwd: obj["cwd"] as? String ?? "",
                    accountID: account.id,
                    accountTag: account.tag,
                    configDir: account.configDir
                ))
            }
        }
        loaded.sort { ($0.state.priority, $1.updatedAt) < ($1.state.priority, $0.updatedAt) }
        return loaded
    }

    private func readUsageFile(_ account: Account) -> Usage {
        var u = Usage()
        guard let data = try? Data(contentsOf: account.usageFile),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return u }

        u.source = .statusline
        u.at = Parse.date(obj["updated_at"])
        if let p = Parse.pct(obj["five_hour_pct"]) {
            u.fiveHour = Limit(pct: p,
                               resetsAt: Parse.date(obj["five_hour_resets_at"]),
                               severity: .fromPct(p))
        }
        if let p = Parse.pct(obj["seven_day_pct"]) {
            u.sevenDay = Limit(pct: p,
                               resetsAt: Parse.date(obj["seven_day_resets_at"]),
                               severity: .fromPct(p))
        }
        return u
    }

    /// Resolve o uso de cada conta e publica a lista que o painel desenha.
    private func publishUsage() {
        accounts = known.map {
            AccountUsage(account: $0, usage: Store.merge(sources[$0.id] ?? Sources()))
        }
    }

    /// Escolhe a fonte mais fresca das quatro **de uma conta**. Comparar por
    /// carimbo, e nao por prioridade fixa, e o que faz o painel nunca andar para
    /// tras: no primeiro segundo o cache do disco ganha, e assim que a API
    /// responde ela assume.
    ///
    /// Depois vem o remendo: a fonte que costuma vencer por frescor -- o
    /// historico do app nativo -- so tem porcentagem. Publicar ela crua zeraria o
    /// countdown de reset e apagaria os creditos extra a cada tick. Entao o
    /// vencedor manda no *numero de uso*, e os campos que ele nao sabe carregar
    /// sao herdados do snapshot mais recente que os tenha.
    private static func merge(_ s: Sources) -> Usage {
        let candidates = [s.api, s.cache, s.history, s.file].filter { $0.at != nil }
        guard var best = candidates.max(by: { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) })
        else { return Usage() }

        let byFreshness = candidates.sorted {
            ($0.at ?? .distantPast) > ($1.at ?? .distantPast)
        }

        // resets_at e agenda, nao medicao: herdar nao inventa uso nenhum, so
        // mantem viva uma data que a fonte vencedora nao transporta.
        //
        // Mas data vencida nao e agenda, e entulho -- e herdar uma marca o
        // vencedor como `rolledOver`, o que apaga a porcentagem da menu bar. Era
        // assim que o robo ficava sozinho na barra sem estar acontecendo nada:
        // maquina parada, statusline sem reescrever `usage.json` desde o ultimo
        // uso do Claude Code, e o historico do app nativo -- fresco, com numero
        // bom -- vestindo um `resets_at` de dois dias atras. Preferir a fonte
        // mais fresca *que ainda tenha data no futuro*; nenhuma tendo, publicar
        // sem countdown, que e a verdade: uso conhecido, agenda desconhecida.
        //
        // Estimativa (PlanHistory.inferReset) conta como ausencia aqui: se
        // alguem tem a data de verdade, ela ganha. A deduzida so fica quando e
        // tudo o que ha.
        let now = Date()
        let exact = { (pick: (Usage) -> Limit?) -> Date? in
            byFreshness.compactMap { u -> Date? in
                guard let l = pick(u), !l.resetsAtIsEstimate else { return nil }
                return l.resetsAt
            }.first { $0 > now }
        }
        if best.fiveHour != nil, best.fiveHour?.resetsAt == nil || best.fiveHour?.resetsAtIsEstimate == true {
            if let d = exact({ $0.fiveHour }) {
                best.fiveHour?.resetsAt = d
                best.fiveHour?.resetsAtIsEstimate = false
            }
        }
        if best.sevenDay != nil, best.sevenDay?.resetsAt == nil || best.sevenDay?.resetsAtIsEstimate == true {
            if let d = exact({ $0.sevenDay }) {
                best.sevenDay?.resetsAt = d
                best.sevenDay?.resetsAtIsEstimate = false
            }
        }

        // Creditos extra so sao herdados quando o vencedor nem tem o campo no
        // formato. Se ele *podia* mandar e nao mandou, o silencio e a resposta --
        // foi assim que o extra_usage sumiu quando o teto mensal estourou, e
        // repescar o valor antigo faria o painel mentir sobre credito disponivel.
        if best.extra == nil, !best.source.carriesExtra {
            best.extra = byFreshness.first(where: { $0.source.carriesExtra })?.extra
        }

        return best
    }

    // MARK: API

    /// A conta que a API cobre -- a padrao, e so ela.
    ///
    /// O token sai do item `Claude Code-credentials` do Keychain, que e o da
    /// instalacao padrao; um config dir proprio guarda a credencial dele em outro
    /// item, cujo nome este projeto ainda nao confirmou. Enquanto nao confirmar,
    /// a resposta da API pertence a conta padrao e a nenhuma outra: atribuir o
    /// numero a conta errada seria pior do que a conta extra ficar sem a fonte 1.
    ///
    /// Na pratica a conta extra nao sente falta: ela e a que vive no terminal,
    /// onde a statusline roda a cada prompt com `rate_limits` vindo do proprio
    /// Claude Code -- mais fresco que qualquer poleio nosso.
    private var apiAccount: Account? { known.first(where: { $0.isDefault }) }

    /// A agenda daquela conta ja esta resolvida? Ou ha countdown no futuro, ou nao
    /// ha janela em curso para datar.
    ///
    /// Serve a uma condicao so -- a de calar o poller -- e existe porque calar por
    /// frescor do *numero* ignorava que a *agenda* podia estar faltando.
    ///
    /// E a continuacao de f25ab6f: la, quando nenhuma fonte tinha data valida, o
    /// painel passou a publicar sem countdown em vez de vestir uma agenda vencida,
    /// e PlanHistory.inferReset cobriu a maioria desses casos deduzindo a janela.
    /// Quando nem ele consegue, so a API tem a data -- e ela estava em silencio.
    ///
    /// Medido em 12/09, numa conta que so vive na extensao do VS Code: statusline
    /// nunca roda (usage.json de 40 dias atras), cache com 56h, historico fresco de
    /// 6 min sem `resets_at`, e inferReset em nil por um vao de 115 min na serie
    /// (app nativo fechado). As quatro fontes tinham numero e nenhuma tinha agenda;
    /// a barra mostrava "100%" sem relogio ate alguem abrir o painel, porque abrir
    /// e o unico caminho que ja passava por cima da economia (panelDidOpen forca).
    ///
    /// Nao vira polling: quem nao tem data volta apenas ao ritmo normal de 300s com
    /// jitter, e o backoff de 429 continua acima disto.
    ///
    /// Uso zerado conta como resolvido, e essa metade tambem custou uma medicao:
    /// com 0% a janela de 5h ainda nem comecou -- ela ancora no primeiro uso --
    /// entao nao existe data nenhuma para buscar, e a barra sem relogio ali e a
    /// verdade. Sem esta clausula, uma maquina parada (que fica em 0% por horas, a
    /// noite inteira) voltaria a poleiar de 300 em 300s para sempre atras de um
    /// campo que ninguem tem. Visto no teste da propria correcao: a janela virou no
    /// meio dele e a API passou a ser consultada a cada ciclo, sem nada a ganhar.
    private func countdownSettled(_ accountID: String) -> Bool {
        guard let five = accounts.first(where: { $0.id == accountID })?.usage.fiveHour
        else { return false }
        if five.pct == 0 { return true }
        guard let reset = five.resetsAt else { return false }
        return reset > Date()
    }

    /// `force` e o clique: abrir o painel ou apertar Atualizar passa por cima do
    /// agendamento e da economia abaixo, mas nunca por cima de um 429 (quem
    /// chama e que decide isso) nem de um fetch ja em voo.
    private func maybeFetchAPI(force: Bool = false) {
        guard !fetching, force || Date() >= nextAPIFetch else { return }
        guard let target = apiAccount else { return }

        // Economia que muda o desenho do app: enquanto o historico do app nativo
        // estiver fresco, ele ja cobre o painel de graca e a requisicao periodica
        // nao melhoraria numero nenhum -- so aumentaria a chance de 429. Fechou o
        // app nativo (ou nunca foi instalado), a serie envelhece e o poller volta
        // sozinho no ciclo seguinte.
        //
        // "Nao melhoraria numero nenhum" tem uma excecao, e ela custou um sintoma:
        // o historico so carrega porcentagem. Sem countdown publicado, a API ainda
        // tem o que trazer -- e era justamente ela que esta economia calava.
        if !force, let at = sources[target.id]?.history.at,
           Date().timeIntervalSince(at) < K.passiveFresh,
           countdownSettled(target.id) {
            scheduleNextFetch(K.apiInterval)
            return
        }

        fetching = true

        // O subprocesso do /usr/bin/security nunca pode rodar na main thread: sao
        // dezenas de ms de fork/exec e a menu bar inteira travaria junto.
        io.async { [weak self] in
            let token = Token.read()
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let token = token else {
                    self.fetching = false
                    self.apiStatus = .noToken
                    self.scheduleNextFetch(K.authRetry)
                    return
                }
                // Nunca renovar: o Claude Code e dono do ciclo de vida do token.
                guard !token.isExpired else {
                    self.fetching = false
                    self.apiStatus = .tokenExpired
                    self.scheduleNextFetch(K.authRetry)
                    return
                }
                self.performFetch(token.bearer, for: target.id)
            }
        }
    }

    private func performFetch(_ token: String, for accountID: String) {
        UsageAPI.fetch(token: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetching = false
                switch result {
                case .success(let u):
                    // Se a conta sumiu enquanto a requisicao estava no ar, o
                    // resultado morre aqui: ele nao tem dono.
                    guard self.sources[accountID] != nil || self.known.contains(where: { $0.id == accountID })
                    else { return }
                    var s = self.sources[accountID] ?? Sources()
                    s.api = u
                    self.sources[accountID] = s
                    self.apiStatus = .ok
                    self.backoff = K.apiInterval
                    self.scheduleNextFetch(K.apiInterval)
                    self.publishUsage()

                case .rateLimited:
                    // 429 aqui persiste por dezenas de minutos e nao manda
                    // Retry-After. Backoff timido so prolonga o castigo.
                    self.backoff = min(max(self.backoff * 2, K.apiBackoffFloor),
                                       K.apiBackoffCeiling)
                    self.scheduleNextFetch(self.backoff)
                    self.apiStatus = .rateLimited(until: self.nextAPIFetch)

                case .unauthorized:
                    self.apiStatus = .tokenExpired
                    self.scheduleNextFetch(K.authRetry)

                case .failure(let why):
                    self.apiStatus = .failed(why)
                    self.scheduleNextFetch(K.apiInterval)
                }
            }
        }
    }

    /// Jitter para nao sincronizar com o polling do proprio Claude Code.
    private func scheduleNextFetch(_ interval: TimeInterval) {
        nextAPIFetch = Date().addingTimeInterval(interval + Double.random(in: -20...20))
    }

    /// Botao "Atualizar": pedido explicito, entao forca a rede mesmo com o
    /// historico fresco. Zera o backoff porque quem apertou quer tentar de novo.
    func refreshNow() {
        nextAPIFetch = .distantPast
        lastPanelFetch = Date()
        backoff = K.apiInterval
        reload()
        scanCost()
        maybeFetchAPI(force: true)
    }

    /// Chamado toda vez que o painel abre.
    ///
    /// O que resolve o buraco de 5 minutos das fontes de disco: elas seguem no
    /// ritmo delas enquanto ninguem esta olhando, e o instante em que voce olha
    /// e o unico em que vale gastar uma requisicao. Clique e ritmo humano, entao
    /// isso nao e polling -- mas o piso existe porque abrir e fechar o painel
    /// tres vezes seguidas nao pode virar tres requisicoes.
    ///
    /// Um 429 em curso e respeitado: durante o castigo o painel se vira com
    /// disco, que e exatamente para isso que as outras tres fontes existem.
    func panelDidOpen() {
        reload()
        if case .rateLimited = apiStatus { return }
        guard Date().timeIntervalSince(lastPanelFetch) >= K.panelRefreshFloor else { return }
        lastPanelFetch = Date()
        nextAPIFetch = .distantPast
        maybeFetchAPI(force: true)
    }
}

// MARK: - Custo e tokens (transcripts locais)

/// Preco de tabela da Anthropic, em dolares por milhao de tokens.
///
/// Os quatro precos de cache derivam do preco de entrada por multiplicadores
/// fixos, entao so a base fica escrita aqui -- uma tabela com cinco colunas por
/// modelo sairia do ar sem ninguem perceber qual celula ficou velha.
private enum Pricing {

    /// Escrita de cache: 1.25x (TTL de 5min) e 2x (1h). Leitura: 0.1x.
    static let write5mMultiplier = 1.25
    static let write1hMultiplier = 2.0
    static let readMultiplier = 0.10

    static func base(for model: String) -> (input: Double, output: Double)? {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus") {
            // Opus 4.1 e anteriores custavam o triplo do Opus atual.
            if m.contains("opus-4-1") || m.contains("opus-4-0") || m.contains("opus-3") {
                return (15, 75)
            }
            return (5, 25)
        }
        if m.contains("sonnet") {
            // Sonnet 5 esta em preco de lancamento ate 31/08/2026.
            if m.contains("sonnet-5"), Date() < Pricing.sonnet5IntroEnds { return (2, 10) }
            return (3, 15)
        }
        if m.contains("haiku") { return (1, 5) }
        return nil   // modelo desconhecido -> conta tokens, nao inventa custo
    }

    private static let sonnet5IntroEnds = Date(timeIntervalSince1970: 1_788_134_400) // 2026-09-01

    static func cost(model: String, _ b: Bucket) -> Double? {
        guard let p = base(for: model) else { return nil }
        let dollars = b.input * p.input
            + b.write5m * p.input * write5mMultiplier
            + b.write1h * p.input * write1hMultiplier
            + b.read * p.input * readMultiplier
            + b.output * p.output
        return dollars / 1_000_000
    }
}

enum Money {
    /// Na menu bar cada ponto de largura conta, e um item que muda de tamanho
    /// empurra os vizinhos -- por isso o formato encolhe conforme o valor cresce.
    static func short(_ v: Double) -> String {
        if v <= 0 { return "$0" }
        if v < 10 { return String(format: "$%.2f", v) }
        if v < 1000 { return String(format: "$%.0f", v) }
        return String(format: "$%.1fk", v / 1000)
    }
    static func full(_ v: Double) -> String { String(format: "$%.2f", v) }
}

enum Tokens {
    static func short(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1e9) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1_000 { return String(format: "%.0fk", v / 1e3) }
        return String(format: "%.0f", v)
    }
}

/// Tokens de um recorte qualquer (um dia, um projeto, um modelo). Double em vez
/// de Int porque some milhoes de tokens e vira dolar fracionado -- converter no
/// fim seria uma casa decimal perdida por soma.
struct Bucket {
    var input = 0.0
    var output = 0.0
    var write5m = 0.0
    var write1h = 0.0
    var read = 0.0
    var cost = 0.0

    var tokens: Double { input + output + write5m + write1h + read }

    static func += (lhs: inout Bucket, rhs: Bucket) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.write5m += rhs.write5m
        lhs.write1h += rhs.write1h
        lhs.read += rhs.read
        lhs.cost += rhs.cost
    }
}

/// Tudo indexado por dia. Qualquer janela (hoje, 7d, 30d) e uma soma de dias, e
/// projeto/modelo ficam aninhados dentro do dia pela mesma razao: sem isso, um
/// "custo por projeto nos ultimos 7 dias" exigiria reprocessar os transcripts.
struct CostStats {
    var days: [String: Bucket] = [:]
    var projects: [String: [String: Bucket]] = [:]
    var models: [String: [String: Bucket]] = [:]
    /// Mesma indexacao por dia das outras duas, com o **id** da conta na chave --
    /// nao a letra, que o dono da maquina pode reescrever a qualquer momento; o
    /// acumulado ficaria orfao da chave antiga. Sem esta dimensao o mesmo projeto
    /// aberto nas duas contas -- o caso comum de quem tem duas -- somaria num
    /// numero unico sem dono.
    var accounts: [String: [String: Bucket]] = [:]

    /// Modelos sem preco na tabela. O painel avisa em vez de mostrar um total
    /// que finge estar completo.
    var unpriced: Set<String> = []
    var scanned = false
}

/// Recorte pronto para a tela.
struct CostReport {
    var total = Bucket()
    var byProject: [(name: String, bucket: Bucket)] = []
    var byModel: [(name: String, bucket: Bucket)] = []
    var byAccount: [(id: String, name: String, bucket: Bucket)] = []
    var daily: [Double] = []     // custo por dia, do mais antigo ao mais novo
    var partial = false
}

extension CostStats {
    /// `days` = 1 devolve so hoje. `accountLabels` traduz id -> letra na hora de
    /// montar o recorte; id sem traducao nao entra, porque uma conta que sumiu
    /// nao tem como ser nomeada na tela.
    func report(days windowDays: Int, accountLabels: [String: String] = [:]) -> CostReport {
        let keys = CostStats.dayKeys(back: windowDays)
        var r = CostReport()
        var projects: [String: Bucket] = [:]
        var models: [String: Bucket] = [:]
        var accounts: [String: Bucket] = [:]

        for key in keys {
            let day = days[key] ?? Bucket()
            r.total += day
            r.daily.append(day.cost)
            for (name, b) in self.projects[key] ?? [:] { projects[name, default: Bucket()] += b }
            for (name, b) in self.models[key] ?? [:] { models[name, default: Bucket()] += b }
            for (name, b) in self.accounts[key] ?? [:] { accounts[name, default: Bucket()] += b }
        }

        r.byProject = projects.map { (name: $0.key, bucket: $0.value) }
            .sorted { $0.bucket.cost > $1.bucket.cost }
        r.byModel = models.map { (name: $0.key, bucket: $0.value) }
            .sorted { $0.bucket.cost > $1.bucket.cost }
        // Por letra, nao por custo: a ordem das contas e estavel no painel e uma
        // lista de duas linhas que troca de ordem sozinha se le como dado mudando
        // quando o que mudou foi so a soma.
        r.byAccount = accounts.compactMap { id, bucket in
            accountLabels[id].map { (id: id, name: $0, bucket: bucket) }
        }.sorted { $0.name < $1.name }
        r.partial = !unpriced.isEmpty && models.keys.contains { unpriced.contains($0) }
        return r
    }

    /// Chaves de dia em ordem cronologica, terminando hoje.
    static func dayKeys(back count: Int) -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: today).map(dayKey)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Leitura dos transcripts do Claude Code (`~/.claude/projects/**/*.jsonl`).
///
/// Zero rede e zero credencial: cada mensagem do assistente ja carrega o
/// `usage` completo e o `cwd` do projeto. E a mesma fonte que os monitores de
/// uso conhecidos usam.
///
/// Os arquivos so crescem no fim, entao a leitura e por deslocamento: a primeira
/// passada varre tudo, as seguintes leem so os bytes novos. Sem isso seriam
/// 300MB reparseados a cada tick.
private enum Transcripts {

    struct Entry {
        let key: String       // id da mensagem + requestId, para deduplicar
        let day: String
        let project: String
        let model: String
        /// Id da conta dona do transcript. Sai do config dir de onde o arquivo foi
        /// lido -- o proprio registro nao diz de quem e.
        let account: String
        let bucket: Bucket
    }

    struct Chunk {
        var entries: [Entry] = []
        var offset: UInt64 = 0
    }

    private static let blockSize = 512 * 1024
    private static let usageMarker = Data("\"usage\"".utf8)

    /// Le de `offset` ate o fim, em blocos. Devolve o novo deslocamento, que
    /// aponta para o fim da ultima linha *completa* -- uma linha pela metade
    /// significa que o Claude Code esta escrevendo agora, e consumi-la perderia
    /// o registro.
    ///
    /// Em blocos, e nao de uma vez, porque a primeira varredura passa por
    /// centenas de MB: carregar arquivo inteiro deixava 200MB residentes num app
    /// que so mostra um robo na barra.
    ///
    /// E com `read(2)` em vez de `FileHandle.read(upToCount:)`. Nao e purismo --
    /// medido nos mesmos 317MB de transcript: FileHandle chegou a 329MB de pico
    /// e 1.81s; o POSIX fez 8.7MB e 0.11s. FileHandle segura tudo o que leu.
    static func read(_ url: URL, from offset: UInt64, account: String) -> Chunk? {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { return nil }

        var chunk = Chunk(entries: [], offset: offset)
        var block = [UInt8](repeating: 0, count: blockSize)
        var carry = Data()   // sobra do bloco anterior: linha cortada no meio

        while true {
            let count = block.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, blockSize)
            }
            if count <= 0 { break }

            var buffer = carry
            buffer.append(contentsOf: block[0..<count])
            carry = Data()

            // JSONSerialization devolve objetos Foundation autoreleased. Sem
            // uma piscina por bloco eles ficam vivos ate o fim da varredura
            // inteira -- medido: 110MB de pico contra 39MB.
            autoreleasepool {
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    chunk.offset += UInt64(line.count + 1)
                    if let entry = parse(line, account: account) { chunk.entries.append(entry) }
                    start = buffer.index(after: newline)
                }
                carry = Data(buffer[start...])
            }
            // `carry` (definido dentro da piscina) e o que sobrou sem \n: pode
            // ser uma linha cortada pelo bloco ou uma escrita em andamento --
            // so o proximo bloco diz qual.
        }

        // `carry` fica de fora de proposito: e a linha incompleta, e `offset`
        // nao avancou sobre ela.
        return chunk
    }

    private static func parse(_ line: Data, account: String) -> Entry? {
        // Filtro por bytes antes do JSON: a esmagadora maioria das linhas e
        // input do usuario e nao tem usage nenhum.
        guard line.range(of: usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              // "<synthetic>" e mensagem fabricada pelo proprio CLI: sem custo.
              model != "<synthetic>",
              let stamp = obj["timestamp"] as? String,
              let date = Parse.date(stamp)
        else { return nil }

        func num(_ key: String, _ dict: [String: Any]) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? 0
        }

        var b = Bucket()
        b.input = num("input_tokens", usage)
        b.output = num("output_tokens", usage)
        b.read = num("cache_read_input_tokens", usage)

        // O TTL da escrita de cache muda o preco em 60%. Quando o detalhamento
        // existe usamos ele; senao cai tudo em 5min, que e o padrao da API.
        if let detail = usage["cache_creation"] as? [String: Any] {
            b.write5m = num("ephemeral_5m_input_tokens", detail)
            b.write1h = num("ephemeral_1h_input_tokens", detail)
        } else {
            b.write5m = num("cache_creation_input_tokens", usage)
        }

        b.cost = Pricing.cost(model: model, b) ?? 0

        let cwd = obj["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "—" : URL(fileURLWithPath: cwd).lastPathComponent
        let id = message["id"] as? String ?? obj["uuid"] as? String ?? UUID().uuidString
        let request = obj["requestId"] as? String ?? ""

        return Entry(key: "\(id)|\(request)", day: CostStats.dayKey(date),
                     project: project, model: model, account: account, bucket: b)
    }
}

extension Transcripts {

    /// O transcript de uma sessao e `<uuid>.jsonl` dentro da pasta do projeto.
    /// Procurar pelo nome em vez de reconstruir o caminho a partir do `cwd` e de
    /// proposito: a codificacao da pasta e destrutiva ("LP F1 Bolão" vira
    /// "-Users-...-LP-F1-Bol-o") e nao da para desfazer. O UUID e unico.
    ///
    /// A busca fica no `projects/` da conta da sessao: e onde o arquivo esta, e
    /// varrer as arvores das outras contas seria procurar onde nao pode haver.
    static func transcript(sessionID: String, in root: URL) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let aiTitleMarker = Data("\"type\":\"ai-title\"".utf8)

    /// Teto da varredura de cabeca. A primeira mensagem costuma estar nos
    /// primeiros KB, mas uma conversa que comeca com print colado empurra ela
    /// para depois de um base64 gordo -- 4MB cobre isso sem varrer um transcript
    /// de 30MB.
    private static let titleScanCap = 4 * 1024 * 1024

    /// Janela de cauda. O Claude Code reescreve a linha `ai-title` quase a cada
    /// turno, entao qualquer pedaco recente do arquivo tem uma.
    private static let tailWindow = 256 * 1024

    /// Titulo da conversa, na ordem de quem manda mais:
    ///
    ///  1. `ai-title` mais recente -- o mesmo texto que a aba do editor mostra.
    ///     Lido pela **cauda**, nao pela cabeca: o titulo e regerado conforme a
    ///     conversa anda, e as duas versoes divergem. Visto num transcript aqui:
    ///     no inicio "Resolver reprovação de produtos...", no fim "Resolver
    ///     rejeição de produtos...". O do fim e o que a aba mostra.
    ///  2. `ai-title` do inicio, se a cauda nao tiver nenhum.
    ///  3. Primeira mensagem do usuario, para os transcripts sem titulo nenhum.
    static func conversationTitle(sessionID: String, in root: URL) -> String? {
        guard let url = transcript(sessionID: sessionID, in: root) else { return nil }
        if let recent = tailAITitle(url) { return recent }
        return headTitle(url)
    }

    /// Le so o fim do arquivo. Custo constante, independente do tamanho.
    private static func tailAITitle(_ url: URL) -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        let size = lseek(descriptor, 0, SEEK_END)
        guard size > 0 else { return nil }
        let from = max(0, size - off_t(tailWindow))
        guard lseek(descriptor, from, SEEK_SET) >= 0 else { return nil }

        var data = Data()
        var block = [UInt8](repeating: 0, count: blockSize)
        while true {
            let count = block.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, blockSize)
            }
            if count <= 0 { break }
            data.append(contentsOf: block[0..<count])
        }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // Se a leitura comecou no meio do arquivo, a primeira "linha" e o rabo
        // de uma linha anterior -- JSON invalido, mas descartar e mais honesto
        // que deixar o parser engolir o erro.
        if from > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            if let title = aiTitle(line) { return title }
        }
        return nil
    }

    /// Varredura de cabeca: pega o primeiro `ai-title` e, na falta dele, a
    /// primeira mensagem do usuario. Percorre ate achar um titulo de IA porque
    /// ele vale mais que a mensagem, e vem depois dela no arquivo.
    private static func headTitle(_ url: URL) -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var block = [UInt8](repeating: 0, count: blockSize)
        var carry = Data()
        var consumed = 0
        var firstUser: String?

        while consumed < titleScanCap {
            let count = block.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, blockSize)
            }
            if count <= 0 { break }
            consumed += count

            var ai: String?
            autoreleasepool {
                var buffer = carry
                buffer.append(contentsOf: block[0..<count])
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    if ai == nil { ai = aiTitle(line) }
                    if firstUser == nil { firstUser = userText(line) }
                    start = buffer.index(after: newline)
                }
                carry = Data(buffer[start...])
            }
            if let ai = ai { return ai }
        }
        return firstUser
    }

    private static func aiTitle(_ line: Data) -> String? {
        guard line.range(of: aiTitleMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "ai-title"
        else { return nil }
        return nonEmpty(obj["aiTitle"] as? String ?? "")
    }

    private static func userText(_ line: Data) -> String? {
        guard line.range(of: userMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "user",
              // Sidechain e turno de subagente: nao e o que voce digitou.
              (obj["isSidechain"] as? Bool) != true,
              let message = obj["message"] as? [String: Any]
        else { return nil }

        if let text = message["content"] as? String { return nonEmpty(text) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = nonEmpty(block["text"] as? String ?? "") { return text }
        }
        // Conversa que comeca so com imagem ou anexo: sem texto para titular.
        return nil
    }

    private static let entrypointMarker = Data("\"entrypoint\":".utf8)

    /// De onde a sessao foi aberta: `claude-vscode`, `claude-desktop`, `cli`.
    ///
    /// O Claude Code carimba isso em toda mensagem do usuario. E o unico dado que
    /// separa duas sessoes do *mesmo* projeto abertas em superficies diferentes:
    /// na arvore de processos elas sao gemeas -- mesmo cwd, mesmo nome de binario
    /// -- e casar pelo cwd focaria a janela da outra.
    ///
    /// Varredura de cabeca, com o mesmo teto do titulo: o carimbo esta na
    /// primeira mensagem, e nao muda no resto da conversa.
    static func entrypoint(sessionID: String, in root: URL) -> String? {
        guard let url = transcript(sessionID: sessionID, in: root) else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var block = [UInt8](repeating: 0, count: blockSize)
        var carry = Data()
        var consumed = 0

        while consumed < titleScanCap {
            let count = block.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, blockSize)
            }
            if count <= 0 { break }
            consumed += count

            var found: String?
            autoreleasepool {
                var buffer = carry
                buffer.append(contentsOf: block[0..<count])
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    if found == nil, line.range(of: entrypointMarker) != nil,
                       let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        found = nonEmpty(obj["entrypoint"] as? String ?? "")
                    }
                    start = buffer.index(after: newline)
                }
                carry = Data(buffer[start...])
            }
            if let found { return found }
        }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Titulo da conversa -- o mesmo texto que a aba do editor mostra.
///
/// Vem da linha `ai-title` do transcript, que o Claude Code reescreve conforme a
/// conversa anda. Presente em 262 dos 284 transcripts aqui; os 22 sem ela caem
/// na primeira mensagem do usuario.
final class SessionTitles {
    private struct Cached {
        var title: String?
        var checkedAt: Date
    }
    private var cache: [String: Cached] = [:]

    /// O titulo nao e fixo: ele e regerado conforme a conversa muda de assunto,
    /// entao o cache expira em vez de congelar o primeiro que viu.
    private let refresh: TimeInterval = 60
    /// Mais curto para quem ainda nao tem titulo: sessao recem-criada nao tem
    /// transcript em disco, e sem retentar ela ficaria pela pasta para sempre.
    private let retry: TimeInterval = 20

    func title(for sessionID: String, in root: URL) -> String? {
        if let cached = cache[sessionID] {
            let window = cached.title == nil ? retry : refresh
            if Date().timeIntervalSince(cached.checkedAt) < window { return cached.title }
        }
        let title = Transcripts.conversationTitle(sessionID: sessionID, in: root)
            .map { SessionTitles.condense($0) }
        cache[sessionID] = Cached(title: title, checkedAt: Date())
        return title
    }

    /// Uma linha so, cortada em fronteira de palavra. O texto cru vem com
    /// quebras e paragrafos inteiros; jogar isso na lista comeria o painel.
    static func condense(_ raw: String, limit: Int = 72) -> String {
        let flat = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return cut[cut.startIndex..<space] + "…"
        }
        return cut + "…"
    }
}

/// Traz a janela que hospeda a sessao para a frente.
///
/// A cadeia toda parte do processo do Claude Code daquela sessao: o pai dele e o
/// extension host, que e um por *janela* do editor -- e a porta que esse host
/// escuta nomeia o `<porta>.lock` que diz qual pasta a janela tem aberta. Abrir
/// essa pasta com o editor faz ele focar aquela janela, sem criar nenhuma.
///
/// Pedir qualquer outro caminho seria pior que nao pedir nada: o editor so
/// reaproveita uma janela quando o caminho e *exatamente* a raiz dela, e quando
/// nao casa ele abre uma janela nova, sem relacao com a sessao. Por isso, sem
/// raiz confirmada, o app so ativa o editor.
///
/// Sessao aberta no app nativo do Claude para no primeiro degrau dessa cadeia:
/// ela nao tem extension host, nao escreve lock, e o app nao abre pasta. Da para
/// dizer qual app hospeda -- e o clique traz ele para a frente --, mas nao qual
/// janela. Ir alem exigiria a API de Acessibilidade, cuja permissao e amarrada a
/// assinatura: sendo este app ad-hoc, ela cairia a cada rebuild.
enum Reveal {

    /// `entrypoint` que o transcript carimba quando a sessao nasceu no app nativo.
    private static let desktopEntrypoint = "claude-desktop"

    /// Descobrir a janela custa ~200 ms de `ps` e `lsof`. Medido: na main thread
    /// isso e um engasgo visivel no painel, entao a busca sai da fila e so o
    /// resultado volta para ela.
    static func session(_ session: Session) {
        DispatchQueue.global(qos: .userInitiated).async {
            let table = processTable()
            // De que lado procurar. Sem isso, uma sessao do app nativo casaria
            // pelo cwd com o processo do editor que tem a mesma pasta aberta --
            // e o clique focaria a janela errada, de outra sessao.
            let desktop = Transcripts.entrypoint(sessionID: session.id,
                                                 in: session.configDir.appendingPathComponent("projects"))
                == desktopEntrypoint
            let process = hostProcess(for: session, desktop: desktop, table)
            // O app sai do processo *daquela* sessao. Com VS Code e Cursor
            // abertos ao mesmo tempo, o primeiro da lista seria o de outra
            // sessao -- e abrir a raiz no app errado abre janela nova nele.
            let host = process.flatMap { editorBundle(hosting: $0.host, table) }
                ?? anyHost(table, desktop: desktop)
            // Sessao do app nativo nao tem janela por pasta: nenhum lock a
            // descreve, e mandar uma pasta para o app do Claude nao foca nada.
            // Sem raiz, o clique so traz o app para a frente -- que e o mais
            // longe que da para ir sem a API de Acessibilidade.
            let root = (host == nil || desktop)
                ? nil : windowRoot(for: session, process, table)
            DispatchQueue.main.async { focus(session, host: host, root: root) }
        }
    }

    private static func focus(_ session: Session, host: URL?, root: URL?) {
        guard let host else {
            // Sessao de terminal, ou app fechado: nao ha janela para focar.
            // Revelar a pasta e honesto; abrir um editor a esmo nao seria.
            guard !session.cwd.isEmpty,
                  FileManager.default.fileExists(atPath: session.cwd) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        guard let root else {
            // Sessao ja encerrada, pasta que nenhuma janela tem aberta, ou app
            // nativo: cai na ultima janela usada em vez de arriscar abrir uma nova.
            NSWorkspace.shared.openApplication(at: host, configuration: config,
                                               completionHandler: nil)
            return
        }
        NSWorkspace.shared.open([root], withApplicationAt: host,
                                configuration: config, completionHandler: nil)
    }

    /// Um processo do Claude Code e quem o hospeda.
    private struct Proc {
        let pid: Int
        /// O pai: o extension host da janela, ou o helper com que o app do Claude
        /// lanca o binario. Nos dois casos e por ele que se chega ao bundle.
        let host: Int
        let command: String
        /// Sessao do app nativo do Claude, nao de um editor. Muda o que da para
        /// focar: o app nao abre pasta, entao nao ha janela a mirar -- so o app.
        let desktop: Bool
    }

    /// Uma passada de `ps`, compartilhada por todo o resto.
    private struct Table {
        /// pid -> linha de comando. So para subir do host ate o bundle `.app`.
        var commands: [Int: String] = [:]
        /// Os processos do Claude Code, com o host de cada um.
        var sessions: [Proc] = []
    }

    private static func processTable() -> Table {
        var table = Table()
        guard let listing = run("/bin/ps", ["-Ao", "pid=,ppid=,command="]) else { return table }
        for line in listing.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), let ppid = Int(fields[1]) else { continue }
            let command = String(fields[2])
            table.commands[pid] = command
            if command.contains("/extensions/anthropic.claude-code") {
                table.sessions.append(Proc(pid: pid, host: ppid, command: command, desktop: false))
            } else if command.contains("/claude-code/"),
                      command.contains("/claude.app/Contents/MacOS/claude") {
                // O app do Claude nao embute o Claude Code: guarda o binario em
                // ~/Library/Application Support/Claude/claude-code/<versao>/ e o
                // lanca por um helper de dentro do proprio bundle -- por isso o
                // marcador do editor nunca casava com essas sessoes.
                table.sessions.append(Proc(pid: pid, host: ppid, command: command, desktop: true))
            }
        }
        // Esse helper repete a linha de comando inteira do binario como argumento,
        // entao casa com o mesmo marcador e entra na lista como se fosse sessao.
        // Quem e pai de outro processo da lista e wrapper: o filho e a sessao.
        let wrappers = Set(table.sessions.filter(\.desktop).map(\.host))
        table.sessions.removeAll { $0.desktop && wrappers.contains($0.pid) }
        return table
    }

    /// Sobe do extension host ate o bundle `.app` que o contem.
    ///
    /// Sem tabela de nomes de editor: o caminho do processo ja diz qual app e,
    /// entao VS Code, Cursor, Windsurf ou qualquer fork funcionam sem o app
    /// precisar conhece-los.
    private static func editorBundle(hosting host: Int, _ table: Table) -> URL? {
        guard let command = table.commands[host],
              let marker = command.range(of: ".app/Contents/") else { return nil }
        // Primeira ocorrencia: em ".../Visual Studio Code.app/Contents/
        // Frameworks/Code Helper (Plugin).app/..." isso da o bundle externo.
        let bundle = String(command[command.startIndex..<marker.lowerBound]) + ".app"
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        return URL(fileURLWithPath: bundle)
    }

    /// Qualquer app do mesmo lado com Claude Code rodando. So para o caso em que
    /// a sessao nao tem mais processo: ai nao ha o que focar, e o clique vira
    /// "traz o app para a frente". Do mesmo lado, sempre: cair no editor porque
    /// a sessao do app nativo acabou seria trocar a janela sem avisar.
    private static func anyHost(_ table: Table, desktop: Bool) -> URL? {
        table.sessions.lazy.filter { $0.desktop == desktop }
            .compactMap { editorBundle(hosting: $0.host, table) }.first
    }

    /// A pasta que a janela daquela sessao tem aberta -- ou nil, se nao der para
    /// afirmar. Nil e um resultado legitimo: melhor ativar o editor do que
    /// chutar um caminho e ganhar uma janela nova.
    private static func windowRoot(for session: Session,
                                   _ process: Proc?,
                                   _ table: Table) -> URL? {
        if let host = process?.host, let port = listeningPort(of: host),
           let folders = folders(inLock: lock(port: port, in: session.configDir)), !folders.isEmpty {
            // Aqui a janela ja esta certa: qualquer raiz dela foca ela. A que
            // contem o cwd e a preferida; sem nenhuma (multi-root), a primeira,
            // que e a raiz pela qual o editor nomeia a janela.
            let root = containing(session.cwd, in: folders) ?? folders[0]
            return URL(fileURLWithPath: root)
        }
        // Host sem porta viva: acontece quando a janela recarrega a extensao e o
        // lock antigo envelhece antes de o novo subir. Cair para as raizes de
        // *todas* as janelas ainda respeita a regra que importa -- so se abre
        // raiz de janela conhecida, nunca um caminho solto. Sem conter o cwd,
        // porem, nao ha o que deduzir: aqui a primeira raiz seria a janela de
        // outro projeto, entao nil e a resposta.
        guard let root = containing(session.cwd, in: openWindowRoots(in: session.configDir))
        else { return nil }
        return URL(fileURLWithPath: root)
    }

    /// A raiz que contem aquele `cwd`, se alguma. Empate entre aninhadas vai
    /// para a mais especifica, para nested workspace nao virar a raiz errada.
    private static func containing(_ cwd: String, in folders: [String]) -> String? {
        guard !cwd.isEmpty else { return nil }
        let cwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        var best: (folder: String, depth: Int)?
        for folder in folders {
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            // Prefixo de *componente*: "/a/b" cobre "/a/b/c", nunca "/a/bc".
            guard cwd == root || cwd.hasPrefix(root + "/") else { continue }
            if best == nil || root.count > best!.depth { best = (folder, root.count) }
        }
        return best?.folder
    }

    /// Raizes de todas as janelas com Claude Code **daquela conta**, lidas dos
    /// locks em disco.
    private static func openWindowRoots(in configDir: URL) -> [String] {
        let dir = configDir.appendingPathComponent("ide")
        let locks = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return locks.filter { $0.pathExtension == "lock" }
            .flatMap { folders(inLock: $0) ?? [] }
    }

    /// Acha o processo do Claude Code daquela sessao.
    ///
    /// `--resume=<id>` e exato, mas so existe em conversa retomada; conversa
    /// nova nao carrega o id em lugar nenhum da linha de comando. Ai o criterio
    /// e o `cwd` do processo, que casa a sessao com a janela mesmo quando o cwd
    /// nao e a raiz dela -- justamente o caso que o casamento por caminho errava.
    ///
    /// A busca ja entra restrita a um lado (editor ou app nativo): o cwd sozinho
    /// nao distingue as duas superficies com o mesmo projeto aberto, e o binario
    /// do app nativo nem carrega `--resume`.
    private static func hostProcess(for session: Session, desktop: Bool, _ table: Table) -> Proc? {
        let candidates = table.sessions.filter { $0.desktop == desktop }
        if let exact = candidates.first(where: { $0.command.contains("--resume=" + session.id) }) {
            return exact
        }
        guard !session.cwd.isEmpty, !candidates.isEmpty else { return nil }
        let target = URL(fileURLWithPath: session.cwd).resolvingSymlinksInPath().path
        let cwds = workingDirectories(of: candidates.map { $0.pid })
        return candidates.first { cwds[$0.pid] == target }
    }

    /// `cwd` de cada pid, numa chamada so. `-F` é o formato estavel do `lsof`:
    /// uma linha por campo, prefixada pela letra do campo (`p` pid, `n` nome).
    private static func workingDirectories(of pids: [Int]) -> [Int: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", list]) else { return [:] }
        var result: [Int: String] = [:]
        var current: Int?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current {
                result[pid] = URL(fileURLWithPath: String(line.dropFirst()))
                    .resolvingSymlinksInPath().path
            }
        }
        return result
    }

    /// A porta TCP que o extension host escuta. E o nome do lock daquela janela.
    private static func listeningPort(of pid: Int) -> String? {
        guard let out = run("/usr/sbin/lsof",
                            ["-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-nP", "-Fn"]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":") {
                let port = line[line.index(after: colon)...]
                if !port.isEmpty, Int(port) != nil { return String(port) }
            }
        }
        return nil
    }

    /// `<config dir>/ide/<porta>.lock` -- o da conta da sessao, nao o da padrao.
    /// Cada conta do Claude Code escreve os locks dela dentro do proprio config
    /// dir; procurar no lugar errado nao acharia nada, ou acharia a janela de uma
    /// sessao de outra conta.
    private static func lock(port: String, in configDir: URL) -> URL {
        configDir.appendingPathComponent("ide/\(port).lock")
    }

    /// Le `~/.claude/ide/<porta>.lock`, que a integracao do Claude Code escreve
    /// com os `workspaceFolders` da janela. Arquivo que ja esta no disco; le-se
    /// so esse campo -- nada aqui abre a conexao que o lock anuncia nem toca no
    /// `authToken` que ele carrega.
    private static func folders(inLock lock: URL) -> [String]? {
        guard let data = try? Data(contentsOf: lock),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let folders = obj["workspaceFolders"] as? [String] else { return nil }
        return folders
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Acumula os transcripts. Vive na fila de IO do Store; nada aqui toca a main.
private final class CostScanner {
    private var cursors: [String: UInt64] = [:]
    private var seen = Set<String>()
    private(set) var stats = CostStats()

    /// Ignora arquivo parado ha mais de 35 dias: a janela maior que o painel
    /// mostra e 30, e sem esse corte a primeira passada varreria o historico
    /// inteiro da maquina.
    private let horizon: TimeInterval = 60 * 60 * 24 * 35

    /// Varre o `projects/` de cada conta. `true` se algo mudou -- so entao vale
    /// republicar para a UI.
    ///
    /// Os cursores sao indexados por caminho absoluto, entao duas contas nunca
    /// disputam o mesmo: incluir uma conta nova e aditivo, e a leitura
    /// incremental das que ja estavam continua de onde parou.
    @discardableResult
    func scan(roots: [(id: String, url: URL)]) -> Bool {
        let fm = FileManager.default
        var changed = false
        let cutoff = Date().addingTimeInterval(-horizon)

        for root in roots {
            guard let walker = fm.enumerator(at: root.url,
                                             includingPropertiesForKeys: [.contentModificationDateKey,
                                                                          .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { continue }

            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified > cutoff else { continue }
                let size = UInt64(values?.fileSize ?? 0)
                let path = url.path
                var offset = cursors[path] ?? 0

                // Arquivo encolheu: foi reescrito, nao apendado. Recomeca do zero.
                if size < offset { offset = 0 }
                guard size > offset else { continue }

                guard let chunk = Transcripts.read(url, from: offset, account: root.id) else { continue }
                cursors[path] = chunk.offset
                for entry in chunk.entries where seen.insert(entry.key).inserted {
                    stats.days[entry.day, default: Bucket()] += entry.bucket
                    stats.projects[entry.day, default: [:]][entry.project, default: Bucket()] += entry.bucket
                    stats.models[entry.day, default: [:]][entry.model, default: Bucket()] += entry.bucket
                    stats.accounts[entry.day, default: [:]][entry.account, default: Bucket()] += entry.bucket
                    if Pricing.base(for: entry.model) == nil { stats.unpriced.insert(entry.model) }
                    changed = true
                }
            }
        }

        if !stats.scanned {
            stats.scanned = true
            changed = true
        }
        return changed
    }
}

// MARK: - Preferencias

/// Modo de exibicao do item da menu bar.
enum BarMode: String, CaseIterable, Identifiable {
    case iconOnly, percent, resetTimer, percentAndReset, costToday

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly:        return "Só o robô"
        case .percent:         return "Uso da sessão (5h)"
        case .resetTimer:      return "Tempo até reiniciar"
        case .percentAndReset: return "Uso + tempo até reiniciar"
        case .costToday:       return "Custo de hoje"
        }
    }
}

/// Como a menu bar sinaliza limite alto.
///
/// O problema e que o fundo ali e o wallpaper, nao uma superficie controlada:
/// texto colorido depende de sorte com o que estiver atras. `.badge` resolve
/// levando o proprio fundo -- e o unico que garante contraste sobre qualquer
/// papel de parede, e por isso e o padrao.
enum BarEmphasis: String, CaseIterable, Identifiable {
    case badge, tint, plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .badge: return "Destaque: etiqueta"
        case .tint:  return "Destaque: cor no número"
        case .plain: return "Destaque: nenhum"
        }
    }
}

/// A unica coisa que este app escreve em disco, e nao e em `~/.claude`:
/// UserDefaults, em ~/Library/Preferences/local.claudebar.plist. Preferencia de
/// exibicao precisa sobreviver ao relaunch; nada mais e persistido, e nenhuma
/// dessas chaves toca dado de uso ou credencial.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let store = UserDefaults.standard

    @Published var barMode: BarMode {
        didSet { store.set(barMode.rawValue, forKey: "barMode") }
    }
    /// Qual conta a menu bar mostra: a da sessao ativa, as duas empilhadas, ou
    /// uma fixa. Guardado como String porque o valor de "fixa" e o id de uma
    /// conta -- que so existe em tempo de execucao e nao cabe num enum.
    @Published var barAccount: String {
        didSet { store.set(barAccount, forKey: "barAccount") }
    }

    /// Como o limite alto aparece na menu bar. Ver BarEmphasis.
    @Published var barEmphasis: BarEmphasis {
        didSet { store.set(barEmphasis.rawValue, forKey: "barEmphasis") }
    }

    /// Letra e nome que o dono da maquina deu a cada conta, por id.
    ///
    /// "P" e "E" sao so o padrao posicional -- servem para quem tem uma pessoal e
    /// uma da empresa e nao servem para mais ninguem. Quem tem duas contas de
    /// cliente, ou tres, precisa escrever a propria legenda.
    @Published var accountTags: [String: String] {
        didSet { store.set(accountTags, forKey: "accountTags") }
    }
    @Published var accountNames: [String: String] {
        didSet { store.set(accountNames, forKey: "accountNames") }
    }

    /// Limite de tamanho da letra. Nao e capricho: cada caractere aqui empurra
    /// todos os vizinhos da menu bar, e o campo aceita texto livre.
    static let maxTagLength = 3

    func setLabel(tag: String, name: String, for id: String) {
        // Vazio apaga a personalizacao em vez de gravar string vazia -- e assim
        // que se volta ao padrao sem precisar de um botao "restaurar".
        let tag = String(tag.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Settings.maxTagLength))
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isEmpty { accountTags.removeValue(forKey: id) } else { accountTags[id] = tag }
        if name.isEmpty { accountNames.removeValue(forKey: id) } else { accountNames[id] = name }
    }
    @Published var costWindow: Int {
        didSet { store.set(costWindow, forKey: "costWindow") }
    }
    @Published var listHeight: Double {
        didSet { store.set(listHeight, forKey: "listHeight") }
    }
    /// Ligada por padrao, mas desligavel: mexer o icone custa ~2.6% de CPU
    /// enquanto o Claude trabalha, e num notebook isso e bateria. Quem preferir
    /// a barra parada nao deveria ter que editar codigo.
    @Published var animateIcon: Bool {
        didSet { store.set(animateIcon, forKey: "animateIcon") }
    }

    /// Segue a conta da sessao que o robo esta descrevendo. E o padrao: com duas
    /// contas, a que voce esta usando agora e quase sempre a que voce quer ver.
    static let barAccountActive = "active"
    /// As duas contas, uma sobre a outra, em corpo menor.
    static let barAccountBoth = "both"

    static let minListHeight: Double = 70
    static let maxListHeight: Double = 420

    private init() {
        // Fallback tambem cobre a migracao: quem tinha "percentAndCount"
        // salvo -- o antigo padrao -- cai em `.percent`, que e o que aquele
        // modo virou quando a contagem saiu da barra.
        barMode = BarMode(rawValue: store.string(forKey: "barMode") ?? "") ?? .percent
        barAccount = store.string(forKey: "barAccount") ?? Settings.barAccountActive
        barEmphasis = BarEmphasis(rawValue: store.string(forKey: "barEmphasis") ?? "") ?? .badge
        accountTags = store.dictionary(forKey: "accountTags") as? [String: String] ?? [:]
        accountNames = store.dictionary(forKey: "accountNames") as? [String: String] ?? [:]
        costWindow = store.object(forKey: "costWindow") as? Int ?? 7
        let saved = store.object(forKey: "listHeight") as? Double ?? 130
        listHeight = min(max(saved, Settings.minListHeight), Settings.maxListHeight)
        animateIcon = store.object(forKey: "animateIcon") as? Bool ?? true
    }
}

// MARK: - Icone da menu bar

/// Cadencia de redesenho do icone. Fica fora do Store de proposito: o painel nao
/// precisa re-renderizar dez vezes por segundo so porque o robo esta mexendo.
final class Pulse: ObservableObject {
    /// Segundos desde que a animacao comecou. Todo movimento e derivado daqui,
    /// nao de um contador de quadros -- assim um tick atrasado desloca a fase em
    /// vez de engasgar o movimento.
    @Published private(set) var phase: Double = 0

    private var timer: Timer?
    private var startedAt = Date()
    private var interval: TimeInterval = 0

    /// 2fps, e nao os 10 que a animacao pediria.
    ///
    /// Nao e economia de estimacao: medido nesta maquina, cada quadro por
    /// segundo do item custa ~1% de CPU **contínuo**, e o gargalo e a propria
    /// menu bar, nao o SwiftUI -- um NSStatusItem cru a 10fps deu 7.6% contra
    /// 10.9% do MenuBarExtra, entao trocar de arquitetura nao compraria nada.
    /// A 10fps isso seriam 10% de CPU pelas horas em que o Claude trabalha.
    ///
    /// A 2fps o movimento tem que ser discreto (ver drawRobot): uma senoide
    /// amostrada tao devagar le como tremor, um ciclo de quatro poses le como
    /// intencao.
    func sync(with state: SessionState) {
        var wanted: TimeInterval = 0
        if Settings.shared.animateIcon {
            switch state {
            case .working, .waiting: wanted = 0.5
            case .done, .idle: wanted = 0
            }
        }
        // Compara o intervalo, nao o estado: assim desligar a animacao nas
        // preferencias tambem para o timer, sem um caminho separado.
        guard wanted != interval else { return }
        interval = wanted

        timer?.invalidate()
        timer = nil
        guard interval > 0 else {
            if phase != 0 { phase = 0 }
            return
        }

        startedAt = Date()
        phase = 0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.phase = Date().timeIntervalSince(self.startedAt)
        }
        // .common pelo mesmo motivo do timer do Store: no modo .default a
        // animacao congelaria enquanto o painel esta aberto.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

/// O que aparece na menu bar e um NSImage desenhado aqui, nao uma `HStack` de
/// SwiftUI.
///
/// O motivo e o alinhamento. O label de `MenuBarExtra` e disposto pelo SwiftUI
/// com a metrica de fonte dele: o simbolo e o texto ganham alturas de linha
/// diferentes e o conjunto assenta alguns pontos fora do eixo dos vizinhos, que
/// sao NSImage centralizados pelo AppKit. Entregando um NSImage pronto de altura
/// fixa (18pt, o padrao de item de menu bar), quem centraliza volta a ser o
/// AppKit -- a mesma conta que todo mundo faz.
enum MenuIcon {
    /// Altura do item. 18pt e o padrao: cabe nos 22pt da menu bar classica e nos
    /// 24pt das telas com notch sem ser recortado nem reescalado.
    static let height: CGFloat = 18
    private static let robotWidth: CGFloat = 14
    private static let gap: CGFloat = 4.5
    /// Respiro entre o texto e a borda da etiqueta.
    private static let badgePadding: CGFloat = 3.5

    /// Digitos monoespacados para a porcentagem nao dancar de largura a cada
    /// ponto percentual -- o item inteiro tremeria na menu bar.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// Corpo das duas linhas do modo "ambas". 12pt nao cabe duas vezes em 18pt de
    /// altura -- duas linhas dessas pedem 24pt e seriam recortadas pela barra.
    /// 8.5pt com peso semibold cabe com folga de 1pt e continua legivel: o peso
    /// compensa o tamanho, que e o mesmo truque dos indicadores nativos que
    /// empilham duas informacoes (bateria com porcentagem, por exemplo).
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)

    static func image(state: SessionState, lines: [BarLine], phase: Double) -> NSImage {
        let face = lines.count > 1 ? stackedFont : font
        let labels = lines.map {
            NSAttributedString(string: $0.text,
                               attributes: [.font: face, .foregroundColor: $0.color])
        }
        // A etiqueta cresce para os lados; a largura do item tem que contar com
        // isso, ou o fundo sairia cortado na borda do NSImage.
        let hasBadge = lines.contains { $0.badge != nil }
        let textWidth = labels.map { ceil($0.size().width) }.max() ?? 0
        let boxWidth = textWidth > 0 ? textWidth + (hasBadge ? badgePadding * 2 : 0) : 0
        let width = robotWidth + (boxWidth > 0 ? gap + boxWidth : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawRobot(state: state, phase: phase)
            // A altura e dividida em tantas faixas quantas forem as linhas, e
            // cada uma e centralizada dentro da sua faixa -- pela altura de
            // caixa-alta, nao pela altura de linha: e o que faz o "54%" bater com
            // o texto dos vizinhos da barra, ja que ascender e descender carregam
            // folga que nao aparece.
            let band = height / CGFloat(max(labels.count, 1))
            for (index, label) in labels.enumerated() {
                // De cima para baixo: a primeira conta e a primeira linha.
                let bottom = height - band * CGFloat(index + 1)
                let baseline = bottom + (band - face.capHeight) / 2
                var x = robotWidth + gap
                if hasBadge { x += badgePadding }

                if let badge = lines[index].badge {
                    // Altura da etiqueta: a caixa-alta mais um respiro, sem nunca
                    // encostar na borda da faixa -- duas etiquetas empilhadas
                    // precisam de um fio entre elas para nao lerem como um bloco
                    // so.
                    let boxH = min(band - 1, face.capHeight + 5)
                    let boxW = ceil(label.size().width) + badgePadding * 2
                    let box = NSRect(x: x - badgePadding, y: bottom + (band - boxH) / 2,
                                     width: boxW, height: boxH)
                    badge.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5).fill()
                }
                label.draw(at: NSPoint(x: x, y: baseline + face.descender))
            }
            return true
        }
        // O handler roda a cada draw, e nao uma vez so: `NSColor.labelColor` e
        // resolvido contra a aparencia da menu bar na hora. Sem isso, alternar
        // claro/escuro deixaria texto preto sobre barra preta ate o proximo
        // tick.
        image.cacheMode = .never
        return image
    }

    /// O mascote do Claude Code: corpo quase quadrado, dois tocos nas laterais,
    /// olhos `>` `<` e as fendas das pernas na base. As proporcoes abaixo sao
    /// fracoes do corpo, tiradas da arte original -- por isso os numeros
    /// magicos vem sempre multiplicados por `bodyW`/`bodyH` em vez de soltos.
    ///
    /// Olhos e fendas sao vazados (`.clear`), nao desenhados por cima. Em 18pt
    /// um tracinho de meio ponto vira borrao; furo no solido continua legivel.
    private static func drawRobot(state: SessionState, phase: Double) {
        let tint = state.barTint
        let bodyW: CGFloat = 10.6
        let bodyH: CGFloat = 11.2
        let nub = bodyW * 0.126            // quanto cada toco lateral avanca
        let cx = robotWidth / 2

        // Quatro poses em vez de uma senoide: a 2fps (ver Pulse) uma curva
        // amostrada le como tremor. Ciclo de 2s -- desce, volta, sobe, volta.
        let frame = state == .working ? Int((phase * 2).rounded(.down)) % 4 : 0
        let bob: CGFloat = [0, -0.6, 0, 0.6][frame]
        let body = NSRect(x: cx - bodyW / 2, y: (height - bodyH) / 2 + bob,
                          width: bodyW, height: bodyH)

        tint.setFill()
        NSBezierPath(roundedRect: body, xRadius: 1.1, yRadius: 1.1).fill()

        let nubH = bodyH * 0.26
        let nubY = body.maxY - bodyH * 0.197 - nubH
        for x in [body.minX - nub + 0.2, body.maxX - 0.2] {
            NSBezierPath(roundedRect: NSRect(x: x, y: nubY, width: nub, height: nubH),
                         xRadius: 0.4, yRadius: 0.4).fill()
        }

        // Vazados. compositingOperation .clear so funciona porque o contexto do
        // NSImage e bitmap com fundo transparente.
        guard let ctx = NSGraphicsContext.current else { return }
        let previous = ctx.compositingOperation
        ctx.compositingOperation = .clear
        defer { ctx.compositingOperation = previous }
        NSColor.black.setFill()   // cor irrelevante em .clear; so a forma conta
        NSColor.black.setStroke()

        // Fendas das pernas: duas fundas nas pontas e um entalhe raso no meio.
        for (fx, fw, fh) in [(0.090, 0.130, 0.280), (0.780, 0.130, 0.280),
                             (0.350, 0.300, 0.206)] {
            NSBezierPath(rect: NSRect(x: body.minX + bodyW * fx, y: body.minY,
                                      width: bodyW * fw, height: bodyH * fh)).fill()
        }

        // Olhos. Em working a abertura do chevron abre e fecha -- o mascote
        // apertando os olhos enquanto pensa. Em waiting eles fecham de vez a
        // cada meio segundo: e o unico estado que quer a sua atencao, e um
        // piscar le como aviso sem precisar de mais uma cor.
        let blinking = state == .waiting
            && phase.truncatingRemainder(dividingBy: 1.0) >= 0.5
        // Aperta e abre no mesmo ciclo de quatro poses do balanco.
        let aperture: CGFloat = state == .working ? [1.0, 0.70, 0.42, 0.70][frame] : 1.0

        let eyeW = bodyW * 0.17
        let eyeH = bodyH * 0.21
        let eyeTop = body.maxY - bodyH * 0.21
        for side in [CGFloat(-1), 1] {
            // side -1 e o olho esquerdo: as duas pontas ficam na borda de fora e
            // o vertice aponta para dentro -- o ">" do mascote, nao um "<".
            let back = side < 0 ? body.minX + bodyW * 0.15 : body.maxX - bodyW * 0.15
            let path = NSBezierPath()
            path.lineWidth = 0.85
            path.lineJoinStyle = .miter
            if blinking {
                path.move(to: NSPoint(x: back, y: eyeTop - eyeH / 2))
                path.line(to: NSPoint(x: back - side * eyeW, y: eyeTop - eyeH / 2))
            } else {
                let tip = back - side * eyeW * aperture
                path.move(to: NSPoint(x: back, y: eyeTop))
                path.line(to: NSPoint(x: tip, y: eyeTop - eyeH / 2))
                path.line(to: NSPoint(x: back, y: eyeTop - eyeH))
            }
            path.stroke()
        }
    }
}

// MARK: - UI

extension Usage {
    /// Origem + idade do dado. Um numero congelado nunca deve se passar por vivo
    /// -- e o que separa um painel confiavel de um que engana.
    var sourceNote: String {
        guard let at = at else { return source.label }
        let secs = Int(Date().timeIntervalSince(at))
        let age = secs < 60 ? "agora" : (secs < 3600 ? "há \(secs / 60)min" : "há \(secs / 3600)h")
        return "\(source.label) · \(age)"
    }
}

/// A letra da conta ("P", "E"). Vai num quadradinho com contorno, e nao como
/// texto solto: na linha da sessao ela divide espaco com modelo e contexto, e
/// sem moldura o "E" leria como mais um pedaco daquele texto.
struct AccountBadge: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.45))
            )
    }
}

/// Os limites de uma conta.
struct UsageCard: View {
    let entry: AccountUsage
    /// Cabecalho so aparece quando ha mais de uma conta. Com uma so, este cartao
    /// e o painel inteiro: repetir ali o email de quem esta logado seria mobilia.
    let showHeader: Bool
    /// Recado da API. So a conta padrao tem -- ver Store.apiAccount.
    let note: String?
    /// Chamado depois de renomear, para a barra e os cartoes pegarem o nome novo
    /// na hora em vez de no proximo tick de 5s.
    let onRename: () -> Void

    @ObservedObject private var settings = Settings.shared
    @State private var editing = false
    @State private var draftTag = ""
    @State private var draftName = ""
    @State private var hovering = false

    var body: some View {
        Card {
            if showHeader {
                if editing { editor } else { header }
            }
            LimitBar(title: "Sessão de 5h", limit: entry.usage.fiveHour,
                     dimmed: entry.usage.isStale)
            LimitBar(title: "Semana (7d)", limit: entry.usage.sevenDay,
                     dimmed: entry.usage.isStale)
            if let extra = entry.usage.extra { ExtraUsageRow(extra: extra) }
            if let note = note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if entry.usage.source == .none {
                Text("Sem dados de limite ainda — abra uma sessão do Claude Code.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            AccountBadge(tag: entry.account.tag)
            Text(entry.account.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            // O lapis so aparece no hover: ele e uma acao rara, e um icone fixo
            // em cada cartao competiria com o dado, que e o que se vem ver.
            if hovering {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(entry.usage.sourceNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            draftTag = entry.account.tag
            draftName = entry.account.name
            editing = true
        }
        .help("Clique para dar um nome e uma letra a esta conta")
    }

    private var editor: some View {
        HStack(spacing: 6) {
            TextField("", text: $draftTag)
                .frame(width: 34)
                .multilineTextAlignment(.center)
                .onChange(of: draftTag) { value in
                    // Cortado na digitacao, e nao so ao salvar: o campo tem 34pt e
                    // texto que nao cabe rolando dentro dele parece bug.
                    let clean = value.replacingOccurrences(of: "\n", with: "")
                    if clean.count > Settings.maxTagLength {
                        draftTag = String(clean.prefix(Settings.maxTagLength))
                    } else if clean != value {
                        draftTag = clean
                    }
                }
            TextField("nome da conta", text: $draftName)
            Button("OK") { commit() }
                .keyboardShortcut(.defaultAction)
        }
        .font(.caption)
        .textFieldStyle(.roundedBorder)
        .onExitCommand { editing = false }
    }

    /// Grava e volta ao cabecalho. Campo vazio nao vira nome vazio: apaga a
    /// personalizacao e a conta volta ao padrao (letra posicional, e-mail).
    private func commit() {
        settings.setLabel(tag: draftTag, name: draftName, for: entry.id)
        editing = false
        onRename()
    }
}

struct LimitBar: View {
    let title: String
    let limit: Limit?
    let dimmed: Bool

    private var color: Color {
        guard let l = limit, !l.rolledOver else { return .secondary }
        return l.severity.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let l = limit, !l.rolledOver {
                    Text("\(Int(l.pct.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(color)
                } else {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * fill)
                }
            }
            .frame(height: 5)

            if let l = limit {
                if l.rolledOver {
                    Text("janela reiniciada").font(.caption2).foregroundStyle(.secondary)
                } else if l.pct == 0, l.resetsAt == nil {
                    // O terceiro estado, que antes nao tinha legenda nenhuma: a
                    // janela nao comecou. Silencio aqui parecia dado faltando.
                    Text("janela começa no próximo uso")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let r = l.resetsAt {
                    // O "~" nao e enfeite: a data deduzida erra minutos, e um
                    // countdown ao segundo sem ele prometeria precisao que nao
                    // existe.
                    Text(l.resetsAtIsEstimate ? "reinicia ~\(r, style: .relative)"
                                              : "reinicia \(r, style: .relative)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    private var fill: CGFloat {
        guard let l = limit, !l.rolledOver else { return 0 }
        return min(max(l.pct / 100, 0), 1)
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Créditos extra").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(extra.pct.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(extra.severity.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(extra.severity.color)
                        .frame(width: geo.size.width * min(max(extra.pct / 100, 0), 1))
                }
            }
            .frame(height: 5)
            Text(extra.capReached
                 ? "teto atingido — \(money(extra.limit))"
                 : "\(money(extra.used)) de \(money(extra.limit))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = extra.currency
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
    }
}

/// Superficie plana com borda de um ponto, nao sombra nem material. Num popover
/// de 340pt, sombra empilhada em tres cartoes vira sujeira; a borda separa os
/// blocos sem competir com o conteudo.
struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            )
    }
}

struct CardTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing = trailing {
                Text(trailing).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Custo por dia em barras, nao em linha. Com sete pontos uma linha sugere
/// continuidade que o dado nao tem: cada dia e uma medida fechada, nao uma
/// amostra de uma curva.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 0.000_001)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == values.count - 1
                              ? Color.accentColor
                              : Color.secondary.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        // Piso de 1pt: um dia com custo zero ainda precisa
                        // ocupar sua coluna, ou o eixo do tempo mente.
                        .frame(height: max(geo.size.height * CGFloat(values[i] / peak), 1))
                }
            }
            .frame(height: geo.size.height, alignment: .bottom)
        }
        .frame(height: 26)
    }
}

struct BreakdownRow: View {
    let name: String
    let bucket: Bucket
    let share: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(Tokens.short(bucket.tokens))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(Money.full(bucket.cost))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.13))
                    .frame(width: geo.size.width * CGFloat(min(max(share, 0), 1)))
            }
        }
    }
}

struct CostCard: View {
    @ObservedObject var store: Store
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let report = store.costReport(days: settings.costWindow)

        Card {
            HStack {
                Text("Custo e tokens").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $settings.costWindow) {
                    Text("Hoje").tag(1)
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 132)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.full(report.total.cost))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text("· \(Tokens.short(report.total.tokens)) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }

            if report.daily.count > 1 { Sparkline(values: report.daily) }

            // Antes de projeto e modelo: com duas contas, "de quem foi este
            // gasto" e a primeira pergunta, e o mesmo projeto pode aparecer nas
            // duas.
            if report.byAccount.count > 1 {
                breakdown("Por conta", report.byAccount.map { (name: $0.name, bucket: $0.bucket) },
                          total: report.total.cost)
            }
            breakdown("Por projeto", report.byProject, total: report.total.cost)
            breakdown("Por modelo", report.byModel, total: report.total.cost)

            if !store.cost.scanned {
                Text("lendo os transcripts…").font(.caption2).foregroundStyle(.secondary)
            } else if report.total.tokens == 0 {
                Text("Nenhum uso registrado nesta janela.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if report.partial {
                Text("Modelo sem preço de tabela — custo abaixo do real.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// Cinco linhas no maximo. Uma lista de vinte projetos num popover nao e
    /// detalhamento, e um lugar onde voce nao acha nada.
    @ViewBuilder
    private func breakdown(_ title: String,
                           _ rows: [(name: String, bucket: Bucket)],
                           total: Double) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.tertiary)
                ForEach(rows.prefix(5), id: \.name) { row in
                    BreakdownRow(name: row.name, bucket: row.bucket,
                                 share: total > 0 ? row.bucket.cost / total : 0)
                }
                if rows.count > 5 {
                    Text("+ \(rows.count - 5) outros")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    /// Ligado so quando ha mais de uma conta -- ver Store.multiAccount.
    let showAccount: Bool
    @State private var hovering = false

    private var canOpen: Bool { !session.cwd.isEmpty }

    var body: some View {
        Button {
            Reveal.session(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.state.symbol)
                    .foregroundStyle(session.state.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.headline)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if showAccount { AccountBadge(tag: session.accountTag) }
                        // A pasta so aparece quando ha titulo: sem ele o titulo
                        // ja e a pasta, e a linha se repetiria.
                        if session.title != nil {
                            Text(session.project)
                        }
                        if !session.model.isEmpty { Text(session.model) }
                        if let context = session.contextPct { Text("ctx \(context)%") }
                        if !session.label.isEmpty { Text(session.label) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering && canOpen {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Sem isto o clique so pega no texto, nao na linha inteira.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && canOpen ? Color.primary.opacity(0.07) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .onHover { hovering = $0 }
        .help(canOpen ? "Ir para a sessão — \(session.cwd)" : "")
    }
}

struct SessionsCard: View {
    @ObservedObject var store: Store
    @ObservedObject private var settings = Settings.shared

    /// Altura no inicio do arraste. Sem isso, cada quadro do gesto somaria a
    /// translacao acumulada de novo e a lista dispararia para o teto.
    @State private var dragOrigin: Double?

    var body: some View {
        Card {
            CardTitle(text: "Sessões",
                      trailing: store.sessions.isEmpty ? nil : "\(store.sessions.count)")
            if store.sessions.isEmpty {
                Text("Nenhuma sessão ativa").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.sessions) {
                            SessionRow(session: $0, showAccount: store.multiAccount)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: settings.listHeight)
                grip
            }
        }
    }

    private var grip: some View {
        ZStack {
            Color.clear
            Capsule().fill(Color.secondary.opacity(0.4))
                .frame(width: 30, height: 4)
        }
        .frame(height: 13)
        // A alca visivel tem 4pt de altura; a area de arraste tem 13. Um alvo
        // de 4pt e caca ao pixel.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = dragOrigin ?? settings.listHeight
                    dragOrigin = origin
                    settings.listHeight = min(max(origin + value.translation.height,
                                                  Settings.minListHeight),
                                              Settings.maxListHeight)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: MenuIcon.image(state: store.headline, lines: [],
                                              phase: store.pulse.phase))
                    .renderingMode(.original)
                Text("Claude Code").font(.headline)
                Spacer()
                // Com varias contas cada cartao carrega a propria origem e idade:
                // um rotulo unico no topo falaria por todas e mentiria para as
                // que estao mais velhas.
                if !store.multiAccount {
                    Text(store.usage.sourceNote).font(.caption2).foregroundStyle(.secondary)
                }
            }

            ForEach(store.accounts) { entry in
                UsageCard(entry: entry,
                          showHeader: store.multiAccount,
                          note: entry.account.isDefault ? store.apiStatus.note : nil,
                          onRename: { store.reload() })
            }

            CostCard(store: store)
            SessionsCard(store: store)

            HStack(spacing: 10) {
                Button("Atualizar") { store.refreshNow() }
                menuBarModeMenu
                Spacer()
                Button("Sair") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
        // Com .menuBarExtraStyle(.window) o conteudo so existe enquanto o painel
        // esta aberto, entao onAppear e literalmente "o usuario abriu".
        .onAppear { store.panelDidOpen() }
    }

    private var menuBarModeMenu: some View {
        Menu {
            ForEach(BarMode.allCases) { mode in
                Button {
                    settings.barMode = mode
                } label: {
                    // O check no proprio item: um Picker dentro de Menu vira
                    // submenu e esconde o modo atual atras de mais um clique.
                    if mode == settings.barMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
            Divider()
            ForEach(BarEmphasis.allCases) { option in
                Button {
                    settings.barEmphasis = option
                } label: {
                    if option == settings.barEmphasis {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
            // So aparece havendo o que escolher: com uma conta, um submenu de
            // "qual conta" seria uma pergunta sem alternativa.
            if store.multiAccount {
                Divider()
                Menu("Conta na barra") {
                    accountChoice(Settings.barAccountActive, "Sessão ativa")
                    accountChoice(Settings.barAccountBoth, "Ambas (duas linhas)")
                    Divider()
                    ForEach(store.accounts) { entry in
                        accountChoice(entry.id, "\(entry.account.tag) — \(entry.account.name)")
                    }
                }
            }
            Divider()
            Button {
                settings.animateIcon.toggle()
                // Aplica na hora em vez de esperar o proximo tick de 5s.
                store.pulse.sync(with: store.headline)
            } label: {
                if settings.animateIcon {
                    Label("Animar o robô", systemImage: "checkmark")
                } else {
                    Text("Animar o robô")
                }
            }
        } label: {
            Text("Menu bar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Item do submenu de conta, com o mesmo check no proprio item que os modos
    /// usam -- um Picker aqui viraria mais um nivel de submenu.
    @ViewBuilder
    private func accountChoice(_ value: String, _ label: String) -> some View {
        Button {
            settings.barAccount = value
        } label: {
            if settings.barAccount == value {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

@main
struct ClaudeBarLocalApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            // O timer sobe no init() do Store, nao aqui: com
            // .menuBarExtraStyle(.window) o conteudo do MenuBarExtra so e
            // instanciado quando o painel abre pela primeira vez, e o app
            // ficaria congelado no estado do launch.
            MenuBarLabel(store: store, pulse: store.pulse)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var pulse: Pulse
    /// Observado aqui tambem: trocar o modo no painel tem que redesenhar a
    /// barra na hora, nao no proximo tick de 5s.
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        // .original: sem isso o SwiftUI trata a imagem como template e joga
        // fora as cores de estado.
        Image(nsImage: MenuIcon.image(state: store.headline,
                                      lines: store.menuLines,
                                      phase: pulse.phase))
            .renderingMode(.original)
    }
}
