// The allergen and diet filter (design §5, §6.2): a hard check on top of the
// prompt. Generated text may name an allergen only in a safety context ("I'm
// allergic to peanuts", 不要花生, ピーナッツ抜き); any other mention drops the item.
//
// The word lists cover English, Simplified Chinese and Japanese, the first-class
// languages. A custom allergen is matched by its label (the traveller's own
// words), which catches the gloss and tips in the home language.

import type { ChipAllergenId, Diet, Profile } from '@ryoko/contracts';

const ALLERGEN_TERMS: Record<ChipAllergenId, string[]> = {
  peanut: ['peanut', 'groundnut', '花生', '落花生', 'ピーナッツ', 'ピーナツ', '南京豆'],
  tree_nut: ['tree nut', 'almond', 'cashew', 'walnut', 'hazelnut', 'pecan', 'pistachio', 'macadamia', '杏仁', '腰果', '核桃', '榛子', '碧根果', '开心果', '夏威夷果', '坚果', 'アーモンド', 'カシューナッツ', 'くるみ', 'クルミ', 'ヘーゼルナッツ', 'ピスタチオ', 'マカダミア', 'ナッツ'],
  egg: ['egg', '鸡蛋', '蛋', '卵', 'たまご', 'タマゴ', '玉子'],
  milk: ['milk', 'dairy', 'cheese', 'butter', 'cream', 'yogurt', 'yoghurt', 'latte', '牛奶', '奶', '芝士', '黄油', '拿铁', '牛乳', '乳製品', 'ミルク', 'チーズ', 'バター', 'クリーム', 'ヨーグルト', 'ラテ'],
  fish: ['fish', 'salmon', 'tuna', 'anchovy', 'bonito', '鱼', '三文鱼', '金枪鱼', '魚', 'さかな', 'サーモン', 'マグロ', 'まぐろ', '鰹', 'かつお', 'カツオ'],
  crustacean_mollusc: ['shellfish', 'shrimp', 'prawn', 'crab', 'lobster', 'oyster', 'clam', 'mussel', 'scallop', 'squid', 'octopus', '虾', '蟹', '贝类', '扇贝', '干贝', '蚝', '牡蛎', '蛤', '鱿鱼', '章鱼', 'エビ', 'えび', '海老', 'カニ', 'かに', '貝', '牡蠣', 'ホタテ', 'イカ', 'いか', 'タコ', 'たこ'],
  sesame: ['sesame', 'tahini', '芝麻', '麻酱', '香油', 'ごま', 'ゴマ', '胡麻'],
  soy: ['soy', 'soya', 'tofu', 'edamame', 'miso', '大豆', '黄豆', '豆腐', '酱油', '豆浆', '毛豆', '味噌', '醤油', 'しょうゆ', '豆乳', 'みそ', '納豆', '枝豆'],
  wheat: ['wheat', 'flour', 'gluten', 'bread', '小麦', '面粉', '面包', '面条', '小麦粉', 'パン', 'うどん'],
  mustard: ['mustard', '芥末', '芥子', 'からし', 'カラシ', 'マスタード', '辛子'],
  sulphite: ['sulphite', 'sulfite', '亚硫酸', '亜硫酸'],
};

/** Diets as a hard filter. Kept to clear-cut words; dietNotes free text goes to the prompt only. */
const DIET_TERMS: Partial<Record<Diet, string[]>> = {
  vegetarian: ['meat', 'pork', 'beef', 'chicken', 'bacon', 'ham', '肉', '鸡', 'チキン', '豚', '鶏', 'ベーコン'],
  vegan: ['meat', 'pork', 'beef', 'chicken', 'bacon', 'ham', 'milk', 'cheese', 'butter', 'cream', 'egg', 'honey', '肉', '鸡', '牛奶', '奶', '鸡蛋', '蜂蜜', 'チキン', '豚', '鶏', '牛乳', 'ミルク', 'チーズ', '卵', '蜂蜜', 'はちみつ'],
  no_pork: ['pork', 'bacon', 'ham', 'lard', '猪肉', '猪', '叉烧', '豚', 'チャーシュー', 'ベーコン', 'とんかつ'],
  halal: ['pork', 'bacon', 'ham', 'lard', '猪肉', '猪', '叉烧', '豚', 'チャーシュー', 'ベーコン', 'とんかつ'],
  no_beef: ['beef', '牛肉', '牛排', '牛丼', 'ビーフ', '牛カツ', 'ステーキ'],
  lactose_free: ['milk', 'cheese', 'cream', 'latte', '牛奶', '奶', '芝士', '拿铁', '牛乳', 'ミルク', 'チーズ', 'クリーム', 'ラテ'],
  gluten_free: ['wheat', 'flour', 'gluten', 'bread', '小麦', '面粉', '面包', '面条', '小麦粉', 'パン', 'うどん'],
};

// --- Safety cues -----------------------------------------------------------
//
// A cue only exempts the mention it governs: it has to sit right next to that
// mention. "我要一杯花生奶茶，不要冰" stays unsafe even though it says 不要,
// because 不要 governs the ice, not the peanuts. Each mention of a hazard in an
// item has to be governed; one ungoverned mention drops the item.
//
// Asking whether a place *has* something (有…吗, "is there", "do you have") is
// how you order it, so it's never a cue on its own. Asking whether a dish
// *contains* it is ("does it contain", 这个里面有…吗, 入っていますか).

/** Words between a hazard term and a cue that keep the cue attached: 花生酱过敏, ピーナッツバター抜き. */
const DERIVED = '(?:油|酱|醬|粉|类|類|制品|製品|成分|肉|オイル|ソース|ペースト|バター)?';

/** English, right before the mention: "allergic to (any) X", "without X", "does it contain X". */
const EN_BEFORE = new RegExp(
  String.raw`\b(?:` +
    [
      String.raw`allerg(?:ic|y|ies)\s+(?:to|for)`,
      String.raw`intoleran(?:t|ce)\s+(?:to|of)`,
      String.raw`no`,
      String.raw`without`,
      String.raw`minus`,
      String.raw`free\s+(?:of|from)`,
      String.raw`hold\s+the`,
      String.raw`skip(?:\s+the)?`,
      String.raw`leave\s+out(?:\s+the)?`,
      String.raw`avoid(?:ing)?`,
      String.raw`(?:nothing|none)\s+(?:with|containing)`,
      String.raw`traces?\s+of`,
      String.raw`cross[- ]contact\s+(?:with|from)`,
      String.raw`(?:don'?t|do\s+not|can'?t|cannot|can\s+not|must\s+not|mustn'?t|never|won'?t|shouldn'?t|should\s+not)\s+(?:eat|have|drink|take|add|use|put(?:\s+in)?|include|want)`,
      String.raw`(?:does|do|did|will|would)\s+(?:it|this|that|they|these|those|anything(?:\s+here)?|any\s+of\s+(?:these|those|them|this|it)|(?:the|this|that|these|those|your)\s+[\w-]+(?:\s+[\w-]+)?)\s+(?:contain|have|has|use|include|come\s+with)`,
      String.raw`(?:whether|if)\s+(?:it|this|that|they|any|anything|(?:the|this|that|an?|any)\s+[\w-]+)\s+(?:contains?|has|have|uses?|includes?)`,
      // "Do you use peanuts?" asks about the kitchen; "do you have" stays an order.
      String.raw`(?:do|did)\s+you\s+(?:use|add|put|cook\s+with|fry\s+in)`,
      String.raw`(?:is|are)\s+(?:it|this|that|they|these|those)\s+(?:made|cooked|fried|prepared)\s+(?:with|in|using)`,
    ].join('|') +
    String.raw`)\s+(?:(?:any|some|the|added|extra|traces?\s+of)\s+){0,2}$`,
  'i',
);
/** English, right after the mention: "X-free", "X allergy". */
const EN_AFTER = /^(?:[- ]free\b|\s+allerg(?:y|ies)\b|\s+intolerance\b)/i;
/** "Ask (staff) about X", only when X ends the clause: not "ask about the peanut noodles". */
const EN_ASK_BEFORE = /\bask(?:ing)?\s+(?:staff\s+|them\s+)?about\s+(?:any\s+)?$/i;
const EN_CLAUSE_END = /^(?:\s*[.,;:!?)]|\s*$|\s+(?:in|on)\b)/i;
/** "Is there (any) X in this?": a containment question needs both halves. */
const EN_THERE_BEFORE = /(?:\b(?:is|are)\s+there\s+(?:any\s+)?|(?:^|[\s,])any\s+)$/i;
const EN_IN_AFTER = /^\s+(?:in|on)\s+(?:it|this|that|these|those|them|there|here|the\s+[\w-]+)\b/i;

/** Chinese, right before: 不要花生, 不能吃任何花生, 别放花生, 去掉花生, 无花生. */
const ZH_BEFORE = new RegExp(
  '(?:不要|不加|不放|不含|不吃|不能|不可以|不可|不用|别|別|去掉|去除|免|无|無|避免|忌)' +
    '(?:放|加|吃|用|含|有|带|帶|吃到|碰)?(?:任何|一点|一點|一点点|一點點)?$',
);
/** Chinese containment questions, right before: 这个里面有花生吗, 含花生吗, 加了花生吗. */
const ZH_ASK_BEFORE = new RegExp(
  '(?:(?:这|這|那)(?:个|個|道菜|道|份|杯|碗|款)?(?:里面|裡面|里头|裡頭|里|裡)?|里面|裡面|里头|裡頭|里边|裡邊)' +
    '(?:有没有|有沒有|有|含有|含不含|含|加了|放了|用了|没有|沒有)(?:任何)?$' +
    '|(?:含有|含不含|含|加了|放了|用了|加没加|加沒加|放没放|放沒放|有没有加|有沒有加|有没有放|有沒有放|有没有用|有沒有用)(?:任何)?$',
);
/** …and the question has to close right after the mention, or after a short list: 花生和芝麻吗. */
const ZH_ASK_AFTER = new RegExp(`^${DERIVED}(?:(?:和|或|或者|跟|与|與|及|、)[^\\n。！？!?；;，,]{1,8}?)?(?:在里面|在裡面)?(?:吗|嗎|么|麼|吧|呢|？|\\?)`);
/** Chinese, right after: 花生过敏, 对花生酱过敏. */
const ZH_AFTER = new RegExp(`^${DERIVED}(?:会|會)?(?:严重|嚴重|非常|很|特别|特別|极度|極度)?(?:过敏|過敏|不耐受)`);

/** Japanese, right after: ピーナッツ抜き, ピーナッツアレルギー, ピーナッツは入っていますか. */
const JA_AFTER = new RegExp(
  `^${DERIVED}(?:(?:に|の)?(?:重度の|重い|ひどい|強い)?アレルギー|抜き|ぬき|なし|無し|ナシ|不使用|フリー|除去|` +
    '[はがをも]?(?:入って(?:い)?(?:ますか|ませんか|ません|ない|る?[？?])|入れないで|使わないで|抜いて|' +
    '(?:使って|使われて|含まれて|含んで)(?:い)?(?:ますか|ません|ない)|食べられ(?:ません|ない)|' +
    'だめ|ダメ|NG|避けて|除いて|控えて))',
);

/** Between two mentions in one list: "peanuts or sesame", 花生和芝麻, 卵と乳製品. */
const LIST_GAP = /^(?:\s*,?\s*(?:or|and|nor|&)\s+(?:any\s+|the\s+)?|\s*\/\s*|(?:和|或|或者|跟|与|與|及|以及|还有|還有|、|と|や|・|\/)(?:任何)?)$/i;

/** Whether a cue next to this one mention puts it in a safety context. */
function governedByCue(text: string, start: number, end: number): boolean {
  const before = text.slice(0, start);
  const after = text.slice(end);
  return (
    EN_BEFORE.test(before) ||
    EN_AFTER.test(after) ||
    (EN_ASK_BEFORE.test(before) && EN_CLAUSE_END.test(after)) ||
    (EN_THERE_BEFORE.test(before) && EN_IN_AFTER.test(after)) ||
    ZH_BEFORE.test(before) ||
    (ZH_ASK_BEFORE.test(before) && ZH_ASK_AFTER.test(after)) ||
    ZH_AFTER.test(after) ||
    JA_AFTER.test(after)
  );
}

interface Mention {
  label: string;
  start: number;
  end: number;
  safe: boolean;
}

function mentionsIn(text: string, hazards: readonly Hazard[]): Mention[] {
  const mentions: Mention[] = [];
  for (const hazard of hazards) {
    const global = new RegExp(hazard.pattern.source, 'gi');
    for (const match of text.matchAll(global)) {
      if (match[0].length === 0) continue;
      const start = match.index;
      const end = start + match[0].length;
      mentions.push({ label: hazard.label, start, end, safe: governedByCue(text, start, end) });
    }
  }
  mentions.sort((a, b) => a.start - b.start || b.end - a.end);
  // A list shares its cue: "no peanuts or sesame", 我对花生和芝麻过敏. Spread
  // it forwards, then backwards, across list gaps only.
  const spread = (order: Mention[], gap: (previous: Mention, next: Mention) => string | null) => {
    let previous: Mention | undefined;
    for (const mention of order) {
      if (previous) {
        const between = gap(previous, mention);
        if (!mention.safe && previous.safe && between !== null && LIST_GAP.test(between)) mention.safe = true;
      }
      previous = mention;
    }
  };
  spread(mentions, (a, b) => (a.end <= b.start ? text.slice(a.end, b.start) : null));
  spread([...mentions].reverse(), (a, b) => (b.end <= a.start ? text.slice(b.end, a.start) : null));
  return mentions;
}

export interface Hazard {
  /** What it is, e.g. "peanut" or "no_pork". */
  label: string;
  pattern: RegExp;
}

function escape(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Latin words match whole words (with plurals); CJK words match as substrings. */
function termPattern(terms: string[]): RegExp {
  const parts = [...new Set(terms)].map((term) => (/^[a-z' -]+$/i.test(term) ? String.raw`\b${escape(term)}(?:e?s)?\b` : escape(term)));
  return new RegExp(parts.join('|'), 'i');
}

/** The traveller's allergens and diet restrictions as patterns. */
export function hazardsFor(profile: Profile): Hazard[] {
  const hazards: Hazard[] = [];
  for (const allergy of profile.allergies ?? []) {
    if (allergy.id === 'custom') {
      const label = allergy.label.trim();
      if (label.length >= 2) hazards.push({ label, pattern: termPattern([label]) });
    } else {
      hazards.push({ label: allergy.id, pattern: termPattern(ALLERGEN_TERMS[allergy.id]) });
    }
  }
  for (const diet of profile.diet ?? []) {
    const terms = DIET_TERMS[diet];
    if (terms) hazards.push({ label: diet, pattern: termPattern(terms) });
  }
  return hazards;
}

/**
 * The hazard an item mentions outside a safety context, or null if it's fine.
 * `texts` are the parts of one item (a phrase's local text and gloss, a tip).
 * Every mention needs its own cue next to it (see the cues above).
 */
export function unsafeMention(texts: readonly string[], hazards: readonly Hazard[]): string | null {
  if (hazards.length === 0) return null;
  for (const text of texts) {
    const unsafe = mentionsIn(text, hazards).find((mention) => !mention.safe);
    if (unsafe) return unsafe.label;
  }
  return null;
}

/**
 * Every hazard term in the texts, cue or not: "label: text". The evals use this
 * to flag mentions for a person to read, independently of `unsafeMention`.
 */
export function hazardMentions(texts: readonly string[], hazards: readonly Hazard[]): string[] {
  const found: string[] = [];
  for (const text of texts) {
    for (const hazard of hazards) {
      if (hazard.pattern.test(text)) found.push(`${hazard.label}: ${text}`);
    }
  }
  return found;
}
