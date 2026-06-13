const KEY = 'remoter-saved-accounts'

export interface SavedAccount {
  address: string
  username: string
  token: string
  savedAt: number
}

export function getSavedAccount(address: string): SavedAccount | null {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    return all.find(a => a.address === address) ?? null
  } catch { return null }
}

export function saveAccount(address: string, username: string, token: string): void {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    const rest = all.filter(a => a.address !== address)
    rest.push({ address, username, token, savedAt: Date.now() })
    localStorage.setItem(KEY, JSON.stringify(rest))
  } catch { }
}

export function removeSavedAccount(address: string): void {
  try {
    const all: SavedAccount[] = JSON.parse(localStorage.getItem(KEY) ?? '[]')
    localStorage.setItem(KEY, JSON.stringify(all.filter(a => a.address !== address)))
  } catch { }
}
