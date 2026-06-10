import React from 'react'
import { FileTransfer } from '../types'

interface Props {
  transfers: FileTransfer[]
  onClose: () => void
}

export function FileTransferPanel({ transfers, onClose }: Props) {
  const active = transfers.filter(t => !t.done)
  return (
    <div style={styles.panel}>
      <div style={styles.header}>
        <span>文件传输{active.length > 0 ? ` · ${active.length} 进行中` : ''}</span>
        <button style={styles.headerClose} onClick={onClose}>×</button>
      </div>
      {transfers.length === 0 ? (
        <div style={styles.empty}>暂无传输任务</div>
      ) : (
        transfers.map(t => <TransferItem key={t.id} transfer={t} />)
      )}
    </div>
  )
}

function TransferItem({ transfer: t }: { transfer: FileTransfer }) {
  const pct = t.size > 0 ? Math.min(100, Math.round(t.transferred / t.size * 100)) : 0
  const dir = t.direction === 'upload' ? '↑' : '↓'
  const color = t.direction === 'upload' ? '#64b5f6' : '#81c784'

  return (
    <div style={styles.item}>
      <div style={styles.itemTop}>
        <span style={{ color, fontWeight: 700, fontSize: 13, marginRight: 4 }}>{dir}</span>
        <span style={styles.filename} title={t.name}>{t.name}</span>
        <span style={styles.pctLabel}>
          {t.error ? '失败' : t.done ? '完成' : `${pct}%`}
        </span>
      </div>
      <div style={styles.progressBg}>
        <div style={{
          ...styles.progressFill,
          width: `${pct}%`,
          background: t.error ? '#f44336' : t.done ? '#4caf50' : color,
        }} />
      </div>
      <div style={styles.itemBottom}>
        <span>{fmtBytes(t.transferred)} / {fmtBytes(t.size)}</span>
        {!t.done && !t.error && t.speedBps > 0 && (
          <span style={{ color: '#888' }}>{fmtSpeed(t.speedBps)}</span>
        )}
      </div>
    </div>
  )
}

function fmtBytes(b: number): string {
  if (b < 1024)           return `${b} B`
  if (b < 1024 * 1024)    return `${(b / 1024).toFixed(1)} KB`
  return `${(b / 1024 / 1024).toFixed(2)} MB`
}

function fmtSpeed(bps: number): string {
  if (bps < 1024)         return `${Math.round(bps)} B/s`
  if (bps < 1024 * 1024)  return `${(bps / 1024).toFixed(0)} KB/s`
  return `${(bps / 1024 / 1024).toFixed(1)} MB/s`
}

const styles: Record<string, React.CSSProperties> = {
  panel: {
    position: 'absolute',
    right: 12,
    bottom: 12,
    width: 320,
    maxHeight: 400,
    overflowY: 'auto',
    background: 'rgba(18,18,30,0.96)',
    backdropFilter: 'blur(14px)',
    borderRadius: 10,
    border: '1px solid rgba(255,255,255,0.1)',
    boxShadow: '0 8px 32px rgba(0,0,0,0.7)',
    zIndex: 200,
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: '10px 14px',
    fontSize: 13,
    fontWeight: 600,
    borderBottom: '1px solid rgba(255,255,255,0.08)',
    position: 'sticky',
    top: 0,
    background: 'rgba(18,18,30,0.98)',
  },
  headerClose: {
    background: 'transparent',
    color: '#888',
    fontSize: 18,
    padding: '0 4px',
    borderRadius: 4,
  },
  empty: {
    padding: '24px 14px',
    fontSize: 13,
    color: '#555',
    textAlign: 'center',
  },
  item: {
    padding: '10px 14px',
    borderBottom: '1px solid rgba(255,255,255,0.05)',
  },
  itemTop: {
    display: 'flex',
    alignItems: 'center',
    marginBottom: 6,
  },
  filename: {
    flex: 1,
    fontSize: 13,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  pctLabel: {
    fontSize: 12,
    color: '#aaa',
    flexShrink: 0,
    marginLeft: 6,
  },
  progressBg: {
    height: 4,
    background: 'rgba(255,255,255,0.1)',
    borderRadius: 2,
    overflow: 'hidden',
    marginBottom: 4,
  },
  progressFill: {
    height: '100%',
    borderRadius: 2,
    transition: 'width 0.25s ease',
  },
  itemBottom: {
    display: 'flex',
    justifyContent: 'space-between',
    fontSize: 11,
    color: '#666',
  },
}
