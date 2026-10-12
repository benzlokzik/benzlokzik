# Counts bytes of code authored by a user per language (git blame over
# linguist-classified files) and renders top-languages SVG cards.
#
# Env: GH_TOKEN (repo + read:org), GH_USER, OUT_DIR, LANGS_COUNT, JOBS
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "linguist"
require "cgi"
require "set"

TOKEN = ENV.fetch("GH_TOKEN")
USER = ENV.fetch("GH_USER")
OUT_DIR = ENV.fetch("OUT_DIR", "img/lang-stats")
LANGS_COUNT = Integer(ENV.fetch("LANGS_COUNT", "12"))
JOBS = Integer(ENV.fetch("JOBS", "8"))

THEMES = {
  "dark" => { title: "#eb1f6a", text: "#f1f1eb", bg: "#272822" },
  "light" => { title: "#7957d5", text: "#363636", bg: "#ffffff" },
}.freeze

def graphql(query, variables = {})
  uri = URI("https://api.github.com/graphql")
  req = Net::HTTP::Post.new(uri, "Authorization" => "bearer #{TOKEN}", "Content-Type" => "application/json")
  req.body = { query: query, variables: variables }.to_json
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  scopes = res["x-oauth-scopes"].to_s.split(/,\s*/)
  unless scopes.include?("repo") && (scopes & %w[read:org write:org admin:org]).any?
    abort "GH_TOKEN needs the repo and read:org scopes, has: #{scopes.join(", ")}"
  end
  body = JSON.parse(res.body)
  raise "GraphQL error: #{body["errors"] || res.code}" if body["errors"] || !res.is_a?(Net::HTTPSuccess)
  body["data"]
end

REPOS_QUERY = <<~GQL
  query($login: String!, $userId: ID!, $after: String) {
    user(login: $login) {
      repositories(ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR], isFork: false, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          nameWithOwner
          defaultBranchRef {
            target {
              ... on Commit {
                history(author: {id: $userId}, first: 100) { totalCount nodes { author { email } } }
              }
            }
          }
        }
      }
    }
  }
GQL

# Repos with at least one commit by the user, plus the emails GitHub links to those commits
def repos_and_emails
  user_id = graphql("query($login: String!) { user(login: $login) { id } }", login: USER)["user"]["id"]
  repos = []
  emails = ["#{USER}@users.noreply.github.com".downcase]
  after = nil
  20.times do
    page = graphql(REPOS_QUERY, login: USER, userId: user_id, after: after)["user"]["repositories"]
    page["nodes"].each do |node|
      history = node.dig("defaultBranchRef", "target", "history")
      next unless history && history["totalCount"].positive?

      repos << node["nameWithOwner"]
      history["nodes"].each { |c| emails << c.dig("author", "email").to_s.downcase }
    end
    break unless page["pageInfo"]["hasNextPage"]

    after = page["pageInfo"]["endCursor"]
  end
  [repos, emails.reject(&:empty?).uniq]
end

# Bytes of lines in `path` whose blamed author email is in `emails`
def authored_bytes(dir, path, emails)
  out, status = Open3.capture2("git", "-C", dir, "blame", "-w", "-M", "-C", "--line-porcelain", "HEAD", "--", path)
  return 0 unless status.success?

  bytes = 0
  author = nil
  out.force_encoding(Encoding::BINARY).each_line do |line|
    if line.start_with?("author-mail ")
      author = line[12..].strip.delete("<>").downcase
    elsif line.start_with?("\t")
      bytes += line.bytesize - 1 if emails.include?(author)
    end
  end
  bytes
end

SEEN_BLOBS = Set.new
SEEN_LOCK = Mutex.new

def repo_stats(name, emails)
  Dir.mktmpdir do |dir|
    url = "https://x-access-token:#{TOKEN}@github.com/#{name}.git"
    _, status = Open3.capture2e("git", "clone", "--quiet", "--no-tags", "--single-branch", url, dir)
    return {} unless status.success?

    rugged = Rugged::Repository.new(dir)
    return {} if rugged.empty?

    tree = rugged.head.target.tree
    files = Linguist::Repository.new(rugged, rugged.head.target_id).breakdown_by_file
    files.to_h do |lang, paths|
      # identical file contents (same blob hash) count once across all repos
      unique = paths.select { |p| SEEN_LOCK.synchronize { SEEN_BLOBS.add?(tree.path(p)[:oid]) } }
      [lang, unique.sum { |p| authored_bytes(dir, p, emails) }]
    end
  end
end

def render(langs, theme)
  t = THEMES.fetch(theme)
  total = langs.sum { |_, b| b }.to_f
  rows = (langs.size / 2.0).ceil
  width = 340
  height = 90 + rows * 25
  bar_x = 0
  bar = langs.map do |name, bytes|
    w = 290 * bytes / total
    rect = %(<rect x="#{bar_x.round(2)}" y="0" width="#{w.round(2)}" height="8" fill="#{color(name)}"/>)
    bar_x += w
    rect
  end
  items = langs.each_with_index.map do |(name, bytes), i|
    x = i < rows ? 0 : 150
    y = (i % rows) * 25
    %(<g transform="translate(#{x}, #{y})"><circle cx="5" cy="6" r="5" fill="#{color(name)}"/>) +
      %(<text x="15" y="10" class="lang">#{CGI.escapeHTML(name)} #{format("%.2f", bytes * 100 / total)}%</text></g>)
  end
  <<~SVG
    <svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Most used languages">
      <style>
        .header { font: 600 18px 'Segoe UI', Ubuntu, Sans-Serif; fill: #{t[:title]}; }
        .lang { font: 400 11px 'Segoe UI', Ubuntu, Sans-Serif; fill: #{t[:text]}; }
      </style>
      <rect x="0.5" y="0.5" rx="4.5" width="#{width - 1}" height="#{height - 1}" fill="#{t[:bg]}"/>
      <text x="25" y="35" class="header">Most Used Languages</text>
      <mask id="bar"><rect x="0" y="0" width="290" height="8" rx="5" fill="white"/></mask>
      <g transform="translate(25, 55)" mask="url(#bar)">#{bar.join}</g>
      <g transform="translate(25, 80)">#{items.join}</g>
    </svg>
  SVG
end

def color(name)
  Linguist::Language[name]&.color || "#858585"
end

repos, emails = repos_and_emails
puts "repos with your commits: #{repos.size}, linked emails: #{emails.size}"

totals = Hash.new(0)
queue = Queue.new
repos.each { |r| queue << r }
lock = Mutex.new
Array.new(JOBS) do
  Thread.new do
    while (name = queue.pop(true) rescue nil)
      stats = repo_stats(name, emails)
      lock.synchronize { stats.each { |lang, bytes| totals[lang] += bytes } }
    end
  end
end.each(&:join)

langs = totals.select { |_, b| b.positive? }.sort_by { |_, b| -b }.first(LANGS_COUNT)
abort "no authored code found" if langs.empty?

Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)
THEMES.each_key { |theme| File.write(File.join(OUT_DIR, "#{theme}.svg"), render(langs, theme)) }
grand = langs.sum { |_, b| b }.to_f
puts langs.map { |n, b| format("%s %.2f%%", n, b * 100 / grand) }.join(" | ")
