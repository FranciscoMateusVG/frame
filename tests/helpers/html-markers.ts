/**
 * A strict little HTML tree for asserting the neutral `data-ttp` smoke
 * markers on server-rendered pages: unbalanced markup throws, text is
 * entity-decoded and whitespace-normalized, like the shared HTTP smoke.
 */

const VOID = new Set(
  'area base br col embed hr img input link meta param source track wbr'.split(' '),
);

const ENTITIES: Record<string, string> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  '#39': "'",
  '#x27': "'",
};

function decode(text: string): string {
  return text.replace(/&(amp|lt|gt|quot|#39|#x27);/g, (_, e: string) => ENTITIES[e] ?? '');
}

export class HtmlNode {
  readonly children: (HtmlNode | string)[] = [];
  constructor(
    readonly tag: string,
    readonly attrs: Readonly<Record<string, string>>,
    readonly parent: HtmlNode | null,
  ) {}

  /** Every descendant carrying `data-ttp="name"`, in document order. */
  marked(name: string): HtmlNode[] {
    const found: HtmlNode[] = [];
    for (const child of this.children) {
      if (typeof child === 'string') continue;
      if (child.attrs['data-ttp'] === name) found.push(child);
      found.push(...child.marked(name));
    }
    return found;
  }

  /** Exactly one descendant marker. */
  one(name: string): HtmlNode {
    const found = this.marked(name);
    if (found.length !== 1) throw new Error(`expected one ${name}, got ${found.length}`);
    return found[0] as HtmlNode;
  }

  /** Entity-decoded, whitespace-normalized text. */
  text(): string {
    return this.raw().split(/\s+/).join(' ').trim();
  }

  /** False when this node or an ancestor is hidden from the user. */
  visible(): boolean {
    const hidden =
      'hidden' in this.attrs ||
      this.attrs['aria-hidden'] === 'true' ||
      (this.tag === 'input' && this.attrs.type === 'hidden') ||
      ['script', 'style', 'template', 'noscript'].includes(this.tag) ||
      /display\s*:\s*none|visibility\s*:\s*hidden/i.test(this.attrs.style ?? '');
    return !hidden && (this.parent === null || this.parent.visible());
  }

  private raw(): string {
    return this.children.map((c) => (typeof c === 'string' ? c : c.raw())).join('');
  }
}

function parseAttrs(attrText: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  for (const a of attrText.matchAll(/([^\s=>]+)(?:="([^"]*)")?/g)) {
    const name = (a[1] as string).toLowerCase();
    if (name in attrs) throw new Error(`duplicate attribute ${name}`);
    attrs[name] = decode(a[2] ?? '');
  }
  return attrs;
}

function closeTag(stack: HtmlNode[], tag: string): void {
  if (VOID.has(tag)) return;
  const top = stack[stack.length - 1] as HtmlNode;
  if (top.tag !== tag.toLowerCase()) throw new Error(`unbalanced </${tag}> in <${top.tag}>`);
  stack.pop();
}

function openTag(stack: HtmlNode[], tag: string, attrText: string): void {
  const top = stack[stack.length - 1] as HtmlNode;
  const node = new HtmlNode(tag.toLowerCase(), parseAttrs(attrText), top);
  top.children.push(node);
  if (!VOID.has(node.tag)) stack.push(node);
}

export function parseHtml(html: string): HtmlNode {
  const root = new HtmlNode('root', {}, null);
  const stack: HtmlNode[] = [root];
  const token =
    /<!--[\s\S]*?-->|<!doctype[^>]*>|<\/([a-z0-9]+)\s*>|<([a-z0-9]+)((?:\s+[^\s=>]+(?:="[^"]*")?)*)\s*\/?>|([^<]+)/gi;
  for (const [, close, open, attrText, text] of html.matchAll(token)) {
    if (text !== undefined) (stack[stack.length - 1] as HtmlNode).children.push(decode(text));
    else if (close !== undefined) closeTag(stack, close);
    else if (open !== undefined) openTag(stack, open, attrText ?? '');
  }
  if (stack.length !== 1) throw new Error('unclosed HTML');
  return root;
}
