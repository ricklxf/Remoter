// Helpers for recursively walking dropped folders (DataTransferItem.webkitGetAsEntry)
// and picked folder inputs (<input webkitdirectory>) into flat UploadEntry lists.

export interface UploadEntry {
  file: File
  relPath?: string
}

interface WebkitFileSystemEntry {
  isFile: boolean
  isDirectory: boolean
  name: string
  file?: (success: (file: File) => void, error?: (err: unknown) => void) => void
  createReader?: () => {
    readEntries: (success: (entries: WebkitFileSystemEntry[]) => void, error?: (err: unknown) => void) => void
  }
}

async function readAllDirectoryEntries(entry: WebkitFileSystemEntry): Promise<WebkitFileSystemEntry[]> {
  if (!entry.createReader) return []
  const reader = entry.createReader()
  const all: WebkitFileSystemEntry[] = []
  while (true) {
    const batch = await new Promise<WebkitFileSystemEntry[]>((resolve) => {
      reader.readEntries(
        (entries) => resolve(entries),
        () => resolve([]),
      )
    })
    if (batch.length === 0) break
    all.push(...batch)
  }
  return all
}

async function walkEntry(entry: WebkitFileSystemEntry, prefix: string, out: UploadEntry[]): Promise<void> {
  const rel = prefix ? `${prefix}/${entry.name}` : entry.name
  if (entry.isFile && entry.file) {
    const file = await new Promise<File | null>((resolve) => {
      entry.file!(
        (f) => resolve(f),
        () => resolve(null),
      )
    })
    if (file) {
      out.push({ file, relPath: prefix ? rel : undefined })
    }
    return
  }
  if (entry.isDirectory) {
    const children = await readAllDirectoryEntries(entry)
    for (const child of children) {
      await walkEntry(child, rel, out)
    }
  }
}

export async function extractDroppedEntries(dt: DataTransfer): Promise<UploadEntry[]> {
  const items = dt.items ? Array.from(dt.items) : []
  const webkitEntries: WebkitFileSystemEntry[] = []
  for (const item of items) {
    const getEntry = (item as DataTransferItem & { webkitGetAsEntry?: () => WebkitFileSystemEntry | null }).webkitGetAsEntry
    if (typeof getEntry === 'function') {
      const entry = getEntry.call(item)
      if (entry) webkitEntries.push(entry)
    }
  }

  if (webkitEntries.length > 0) {
    const out: UploadEntry[] = []
    for (const entry of webkitEntries) {
      await walkEntry(entry, '', out)
    }
    if (out.length > 0) return out
  }

  return Array.from(dt.files).map((file) => ({ file }))
}

export function extractPickedEntries(fileList: FileList | null): UploadEntry[] {
  if (!fileList || fileList.length === 0) return []
  return Array.from(fileList).map((file) => {
    const rel = (file as File & { webkitRelativePath?: string }).webkitRelativePath
    return {
      file,
      relPath: rel && rel.includes('/') ? rel : undefined,
    }
  })
}
