const KEY = 'remoter-saved-accounts'

export interface SavedAccount {
  address: string
  username: string
  token: string
  savedAt: number
}

/** 返回某地址下所有已记住的账户，按最新在前排序 */
export function getSavedAccounts(address: string): SavedAccount[] {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    return all
      .filter(a => a.address === address)
      .sort((a, b) => b.savedAt - a.savedAt)
  } catch { return [] }
}

/** 兼容旧调用，返回最新的一个账户 */
export function getSavedAccount(address: string): SavedAccount | null {
  return getSavedAccounts(address)[0] ?? null
}

/** 按 (address, username) upsert，同一用户重复登录只保留最新 token */
export function saveAccount(address: string, username: string, token: string): void {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    const rest = all.filter(a => !(a.address === address && a.username === username))
    rest.push({ address, username, token, savedAt: Date.now() })
    localStorage.setItem(KEY, JSON.stringify(rest))
  } catch { }
}

/** username 缺省时删除该地址下所有账户 */
export function removeSavedAccount(address: string, username?: string): void {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    const filtered = username
      ? all.filter(a => !(a.address === address && a.username === username))
      : all.filter(a => a.address !== address)
    localStorage.setItem(KEY, JSON.stringify(filtered))
  } catch { }
}
