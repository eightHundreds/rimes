import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type WheelEvent,
} from "react";
import { Icon } from "../design-system/Icon";
import { Button, IconButton, Segmented } from "../design-system/primitives";
import rimesAppIconURL from "../../../Logo/AppIcon.iconset/icon_256x256.png";

export type ClipboardProtection =
  | "none"
  | "secure-input"
  | "locked"
  | "sleeping"
  | "inactive";

export type ClipboardActivationDestination = "target" | "pasteboard";
export type ClipboardSurfaceItemKind = "text" | "link" | "image" | "files";

export type ClipboardSurfaceItem = {
  id: string;
  text: string;
  kind?: ClipboardSurfaceItemKind;
  previewImageURL?: string;
  sourceApplication?: string;
  sourceApplicationIconURL?: string;
  capturedAt?: string;
};

export type ClipboardSurfaceFeedback = {
  destination?: ClipboardActivationDestination;
  itemID?: string;
  message: string;
  tone: "neutral" | "accent" | "warning";
};

export type ClipboardSurfaceProps = {
  className?: string;
  initialCaptureEnabled?: boolean;
  initialItems?: readonly ClipboardSurfaceItem[];
  initialProtection?: ClipboardProtection;
  initialSelectedID?: string;
  initialTargetAvailable?: boolean;
  onActivate?: (
    item: ClipboardSurfaceItem,
    destination: ClipboardActivationDestination,
  ) => void;
  onFeedback?: (feedback: ClipboardSurfaceFeedback) => void;
  onItemsChange?: (items: ClipboardSurfaceItem[]) => void;
  showControls?: boolean;
};

const sampleClipboardItems: readonly ClipboardSurfaceItem[] = [
  {
    id: "clipboard-image-preview",
    text: "RIMES App Icon · 256 × 256 PNG",
    kind: "image",
    previewImageURL: rimesAppIconURL,
    sourceApplication: "RIMES",
    sourceApplicationIconURL: rimesAppIconURL,
    capturedAt: "NOW",
  },
  {
    id: "clipboard-design-tokens",
    text: "候选框、Buffer 与 Clipboard History 要共享同一套设计令牌。",
    kind: "text",
    sourceApplication: "Codex",
    capturedAt: "2M",
  },
  {
    id: "clipboard-build-command",
    text: "npm run typecheck && npm run test -- --run",
    kind: "text",
    sourceApplication: "Terminal",
    capturedAt: "8M",
  },
  {
    id: "clipboard-theme-note",
    text: "墨竹、翡翠与静谧都必须保持清晰对比度。",
    kind: "text",
    sourceApplication: "Obsidian",
    capturedAt: "1H",
  },
  {
    id: "clipboard-release-link",
    text: "https://github.com/young-bo-i/rime-buffer/releases/latest",
    kind: "link",
    sourceApplication: "Safari",
    capturedAt: "3H",
  },
  {
    id: "clipboard-privacy-note",
    text: "历史保存在本机私有数据库；支持图片预览，不进行云同步。",
    kind: "text",
    sourceApplication: "Notes",
    capturedAt: "5H",
  },
];

const protectionOptions = [
  { value: "none", label: "正常" },
  { value: "secure-input", label: "Secure Input" },
  { value: "locked", label: "锁屏" },
] as const;

const targetOptions = [
  { value: "available", label: "目标可用" },
  { value: "missing", label: "无目标" },
] as const;

function copyItems(items: readonly ClipboardSurfaceItem[]) {
  return items.map((item) => ({ ...item }));
}

function boundedPreview(text: string, maximumCharacters = 280) {
  const normalized = text.replace(/[\r\n\t]+/g, " ");
  return normalized.length > maximumCharacters
    ? `${normalized.slice(0, maximumCharacters)}…`
    : normalized;
}

function filterItems(items: readonly ClipboardSurfaceItem[], query: string) {
  const terms = query.trim().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [...items];
  return items.filter((item) => terms.every((term) => {
    const lowered = term.toLocaleLowerCase();
    const kindAliases: Record<ClipboardSurfaceItemKind, string> = {
      text: "text 文本 文字",
      link: "link url 链接 网址",
      image: "image photo picture 图片 图像 照片",
      files: "file files 文件",
    };
    return item.text.toLocaleLowerCase().includes(lowered)
      || item.sourceApplication?.toLocaleLowerCase().includes(lowered)
      || kindAliases[item.kind ?? "text"].includes(lowered);
  }));
}

function protectionMessage(protection: ClipboardProtection) {
  switch (protection) {
    case "secure-input": return "安全输入期间已隐藏历史";
    case "locked": return "屏幕锁定期间已隐藏历史";
    case "sleeping": return "睡眠期间已暂停剪贴板读取";
    case "inactive": return "当前会话已保护";
    case "none": return "";
  }
}

function commandDigitIndex(key: string) {
  return /^[1-9]$/.test(key) ? Number(key) - 1 : undefined;
}

/**
 * Interactive mirror of the standalone native Clipboard History panel.
 * The browser demo models logical search and exact-target delivery, while the
 * real nonactivating AppKit panel keeps the external FocusToken authoritative.
 */
export function ClipboardSurface({
  className = "",
  initialCaptureEnabled = true,
  initialItems = sampleClipboardItems,
  initialProtection = "none",
  initialSelectedID,
  initialTargetAvailable = true,
  onActivate,
  onFeedback,
  onItemsChange,
  showControls = true,
}: ClipboardSurfaceProps) {
  const itemSnapshot = useMemo(() => copyItems(initialItems), [initialItems]);
  const keyboardZoneRef = useRef<HTMLElement>(null);
  const cardRowRef = useRef<HTMLDivElement>(null);
  const cardRefs = useRef(new Map<string, HTMLButtonElement>());
  const [items, setItems] = useState<ClipboardSurfaceItem[]>(itemSnapshot);
  const [captureEnabled, setCaptureEnabled] = useState(initialCaptureEnabled);
  const [protection, setProtection] = useState<ClipboardProtection>(initialProtection);
  const [targetAvailable, setTargetAvailable] = useState(initialTargetAvailable);
  const [query, setQuery] = useState("");
  const [visible, setVisible] = useState(true);
  const [selectedID, setSelectedID] = useState<string | undefined>(() => {
    if (initialSelectedID && itemSnapshot.some((item) => item.id === initialSelectedID)) {
      return initialSelectedID;
    }
    return itemSnapshot[0]?.id;
  });
  const [feedback, setFeedback] = useState<ClipboardSurfaceFeedback>();

  const protectedContent = protection !== "none";
  const filteredItems = useMemo(
    () => protectedContent || !captureEnabled ? [] : filterItems(items, query),
    [captureEnabled, items, protectedContent, query],
  );
  const selectedIndex = filteredItems.findIndex((item) => item.id === selectedID);
  const selectedItem = selectedIndex >= 0 ? filteredItems[selectedIndex] : filteredItems[0];

  useEffect(() => {
    if (protectedContent) setQuery("");
  }, [protectedContent]);

  useEffect(() => {
    if (selectedID && filteredItems.some((item) => item.id === selectedID)) return;
    setSelectedID(filteredItems[0]?.id);
  }, [filteredItems, selectedID]);

  useEffect(() => {
    if (!visible || !selectedID) return;
    const row = cardRowRef.current;
    const card = cardRefs.current.get(selectedID);
    if (!row || !card) return;
    const visibleLeft = row.scrollLeft;
    const visibleRight = visibleLeft + row.clientWidth;
    if (card.offsetLeft < visibleLeft) {
      row.scrollTo({ left: card.offsetLeft, behavior: "smooth" });
    } else if (card.offsetLeft + card.offsetWidth > visibleRight) {
      row.scrollTo({
        left: card.offsetLeft + card.offsetWidth - row.clientWidth,
        behavior: "smooth",
      });
    }
  }, [selectedID, visible]);

  function publishFeedback(next: ClipboardSurfaceFeedback) {
    setFeedback(next);
    onFeedback?.(next);
  }

  function publishItems(next: ClipboardSurfaceItem[]) {
    setItems(next);
    onItemsChange?.(next);
  }

  function promote(item: ClipboardSurfaceItem) {
    const next = [item, ...items.filter((candidate) => candidate.id !== item.id)];
    publishItems(next);
    setSelectedID(item.id);
  }

  function activateItem(item = selectedItem) {
    if (!item || protectedContent || !captureEnabled) {
      publishFeedback({ message: "当前没有可上屏的剪贴板条目", tone: "warning" });
      return;
    }
    if (!targetAvailable) {
      publishFeedback({
        itemID: item.id,
        message: "当前没有可验证的输入目标",
        tone: "warning",
      });
      return;
    }
    promote(item);
    const next = {
      destination: "target" as const,
      itemID: item.id,
      message: "已通过精确输入目标上屏",
      tone: "accent" as const,
    };
    publishFeedback(next);
    onActivate?.(item, "target");
  }

  function copyItem(item = selectedItem) {
    if (!item || protectedContent || !captureEnabled) {
      publishFeedback({ message: "当前没有可复制的剪贴板条目", tone: "warning" });
      return;
    }
    const next = {
      destination: "pasteboard" as const,
      itemID: item.id,
      message: "已复制；不会作为新历史重复收录",
      tone: "accent" as const,
    };
    publishFeedback(next);
    onActivate?.(item, "pasteboard");
  }

  function deleteSelected() {
    if (!selectedItem || protectedContent || !captureEnabled) return;
    const itemIndex = items.findIndex((item) => item.id === selectedItem.id);
    const next = items.filter((item) => item.id !== selectedItem.id);
    publishItems(next);
    setSelectedID(next[itemIndex]?.id ?? next[itemIndex - 1]?.id ?? next[0]?.id);
    publishFeedback({
      itemID: selectedItem.id,
      message: "已从本机剪贴板历史删除",
      tone: "neutral",
    });
  }

  function moveSelection(delta: -1 | 1) {
    if (filteredItems.length === 0) return;
    const current = selectedIndex >= 0 ? selectedIndex : 0;
    const next = Math.min(filteredItems.length - 1, Math.max(0, current + delta));
    setSelectedID(filteredItems[next].id);
  }

  function closeOrClearSearch() {
    if (query) {
      setQuery("");
      publishFeedback({ message: "已清除搜索", tone: "neutral" });
      return;
    }
    setVisible(false);
    publishFeedback({ message: "Clipboard History 已关闭", tone: "neutral" });
  }

  function handleKeyboard(event: KeyboardEvent<HTMLElement>) {
    if (!visible || protectedContent) return;
    if (event.metaKey && !event.altKey && !event.ctrlKey) {
      if (event.key.toLocaleLowerCase() === "f") {
        event.preventDefault();
        return;
      }
      if (event.key.toLocaleLowerCase() === "c") {
        event.preventDefault();
        copyItem();
        return;
      }
      const quickIndex = commandDigitIndex(event.key);
      if (quickIndex !== undefined) {
        event.preventDefault();
        activateItem(filteredItems[quickIndex]);
        return;
      }
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    switch (event.key) {
      case "ArrowLeft":
        event.preventDefault();
        moveSelection(-1);
        return;
      case "ArrowRight":
        event.preventDefault();
        moveSelection(1);
        return;
      case "Enter":
        event.preventDefault();
        activateItem();
        return;
      case "Backspace":
      case "Delete":
        event.preventDefault();
        if (query) setQuery((current) => current.slice(0, -1));
        else deleteSelected();
        return;
      case "Escape":
        event.preventDefault();
        closeOrClearSearch();
        return;
      default:
        break;
    }

    if (event.key.length === 1) {
      event.preventDefault();
      setQuery((current) => `${current}${event.key}`);
    }
  }

  function translateWheel(event: WheelEvent<HTMLDivElement>) {
    if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
    event.currentTarget.scrollLeft += event.deltaY;
  }

  function resetItems() {
    const next = copyItems(itemSnapshot);
    publishItems(next);
    setSelectedID(next[0]?.id);
    setQuery("");
    setFeedback(undefined);
    setVisible(true);
    requestAnimationFrame(() => keyboardZoneRef.current?.focus());
  }

  const stateMessage = protectedContent
    ? protectionMessage(protection)
    : !captureEnabled
      ? "剪贴板历史收录已关闭"
      : query && filteredItems.length === 0
        ? "没有匹配的记录"
        : "尚无剪贴板记录";

  return (
    <section className={`clipboard-surface ${className}`.trim()}>
      {showControls ? (
        <header className="clipboard-surface__controls">
          <div className="clipboard-surface__control-group">
            <span className="clipboard-surface__control-label">窗口状态</span>
            <Segmented
              ariaLabel="Clipboard History 保护状态"
              onChange={(value) => {
                setProtection(value);
                setVisible(true);
                setFeedback(undefined);
              }}
              options={protectionOptions}
              value={protection === "sleeping" || protection === "inactive"
                ? "secure-input"
                : protection}
            />
          </div>
          <div className="clipboard-surface__control-group">
            <span className="clipboard-surface__control-label">输入目标</span>
            <Segmented
              ariaLabel="Clipboard History 输入目标"
              onChange={(value) => setTargetAvailable(value === "available")}
              options={targetOptions}
              value={targetAvailable ? "available" : "missing"}
            />
          </div>
          <div className="clipboard-surface__control-actions">
            <Button
              icon={captureEnabled ? "check" : "clipboard"}
              kind={captureEnabled ? "secondary" : "ghost"}
              onClick={() => {
                setCaptureEnabled((enabled) => !enabled);
                setQuery("");
                setVisible(true);
              }}
            >
              {captureEnabled ? "停止本次收录" : "开启本次收录"}
            </Button>
            <Button icon="trash" kind="danger" onClick={deleteSelected}>删除所选</Button>
          </div>
        </header>
      ) : null}

      <div className="clipboard-surface__stage">
        {visible ? (
          <section
            aria-label="Clipboard History"
            className="clipboard-history-window"
            onClick={() => keyboardZoneRef.current?.focus()}
            onKeyDown={handleKeyboard}
            ref={keyboardZoneRef}
            tabIndex={protectedContent ? -1 : 0}
          >
            <header className="clipboard-history-window__header">
              <strong>Clipboard History</strong>
              <span className="clipboard-history-window__count">
                {query ? `${filteredItems.length} / ${items.length}` : `${items.length} ITEMS`}
              </span>
              <span aria-hidden="true" className="clipboard-history-window__spacer" />
              <div
                aria-label="搜索剪贴板历史；直接输入"
                className={`clipboard-history-search${query ? " has-query" : ""}`}
                role="search"
              >
                <Icon name="search" size={14} weight="bold" />
                <span>{query || "直接输入以搜索"}</span>
              </div>
              <Button
                disabled={protectedContent || items.length === 0}
                kind="ghost"
                onClick={(event) => {
                  event.stopPropagation();
                  publishItems([]);
                  setSelectedID(undefined);
                  setQuery("");
                  publishFeedback({ message: "已清空本机剪贴板历史", tone: "neutral" });
                }}
              >
                清空
              </Button>
              <IconButton
                icon="close"
                label="关闭 Clipboard History"
                onClick={(event) => {
                  event.stopPropagation();
                  setVisible(false);
                }}
              />
            </header>

            <div className="clipboard-history-window__timeline">
              {protectedContent || !captureEnabled || filteredItems.length === 0 ? (
                <div className="clipboard-history-window__state" role="status">
                  <Icon
                    name={protectedContent ? "lock" : "clipboard"}
                    size={17}
                    weight="bold"
                  />
                  <span>{stateMessage}</span>
                </div>
              ) : (
                <div
                  aria-label="剪贴板历史卡片"
                  aria-orientation="horizontal"
                  className="clipboard-history-window__cards"
                  onWheel={translateWheel}
                  ref={cardRowRef}
                  role="listbox"
                >
                  {filteredItems.map((item, index) => {
                    const selected = item.id === selectedItem?.id;
                    const kind = item.kind ?? "text";
                    const hasImagePreview = Boolean(item.previewImageURL);
                    return (
                      <button
                        aria-label={`${hasImagePreview ? "图片预览 · " : ""}${boundedPreview(item.text, 512)}`}
                        aria-selected={selected}
                        className={`clipboard-history-card${selected ? " is-selected" : ""}`}
                        key={item.id}
                        onClick={(event) => {
                          event.stopPropagation();
                          setSelectedID(item.id);
                          keyboardZoneRef.current?.focus();
                        }}
                        onDoubleClick={(event) => {
                          event.stopPropagation();
                          activateItem(item);
                        }}
                        ref={(node) => {
                          if (node) cardRefs.current.set(item.id, node);
                          else cardRefs.current.delete(item.id);
                        }}
                        role="option"
                        type="button"
                      >
                        <span className="clipboard-history-card__meta">
                          <b>{index < 9 ? `⌘${index + 1}` : kind.toLocaleUpperCase()}</b>
                          <span className="clipboard-history-card__source">
                            {item.sourceApplicationIconURL ? (
                              <img
                                alt=""
                                aria-hidden="true"
                                src={item.sourceApplicationIconURL}
                              />
                            ) : null}
                            <span>{item.sourceApplication ?? kind.toLocaleUpperCase()}</span>
                          </span>
                          <time>{item.capturedAt ?? "NOW"}</time>
                        </span>
                        {hasImagePreview ? (
                          <span className="clipboard-history-card__image-preview">
                            <img alt={item.text || "剪贴板图片预览"} src={item.previewImageURL} />
                          </span>
                        ) : (
                          <span className="clipboard-history-card__preview">
                            {boundedPreview(item.text)}
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>

            <footer className="clipboard-history-window__hint">
              TYPE TO SEARCH&nbsp;&nbsp; ← → SELECT&nbsp;&nbsp; ↩ INSERT&nbsp;&nbsp;
              ⌘1–9 QUICK INSERT&nbsp;&nbsp; ⌘C COPY&nbsp;&nbsp; DELETE REMOVE&nbsp;&nbsp; ESC CLOSE
            </footer>
          </section>
        ) : (
          <div className="clipboard-surface__closed">
            <Icon name="clipboard" size={24} weight="duotone" />
            <span>
              <strong>Clipboard History 已关闭</strong>
              <small>⌘⇧P 从当前屏幕底部重新打开</small>
            </span>
            <Button
              icon="eye"
              kind="primary"
              onClick={() => {
                setVisible(true);
                requestAnimationFrame(() => keyboardZoneRef.current?.focus());
              }}
            >
              重新打开
            </Button>
          </div>
        )}
      </div>

      <footer className="clipboard-surface__legend">
        <span>本机私有 · 文本 / 链接 / 图片 / 文件 · 不云同步</span>
        <span>图片卡片异步预览，并显示来源 App 图标</span>
        <span>{targetAvailable ? "精确输入目标可用" : "输入目标不可验证；仍可 ⌘C 复制"}</span>
        {feedback ? <output aria-live="polite">{feedback.message}</output> : null}
        <span className="clipboard-surface__legend-spacer" />
        <Button kind="ghost" onClick={() => publishItems([])}>空状态</Button>
        <Button kind="ghost" onClick={resetItems}>恢复示例</Button>
      </footer>
    </section>
  );
}
