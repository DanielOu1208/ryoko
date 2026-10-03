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

/**
 * Words that put a mention in a safety context: allergy statements, "without",
 * asking whether something is in a dish.
 */
const SAFETY_CONTEXT = new RegExp(
  [
    // English
    String.raw`\ballerg\w*`,
    String.raw`\bwithout\b`,
    String.raw`\bno\b`,
    String.raw`\bnot\b`,
    String.raw`\bnever\b`,
    String.raw`\bavoid\w*`,
    String.raw`[\w-]*free\b`,
    String.raw`\bdon'?t\b`,
    String.raw`\bdo not\b`,
    String.raw`\bcan'?t\b`,
    String.raw`\bcannot\b`,
    String.raw`\bmust not\b`,
    String.raw`\bleave (?:it |them )?out\b`,
    String.raw`\bhold the\b`,
    String.raw`\bskip\b`,
    String.raw`\bcontain\w*`,
    String.raw`\b(?:is|are) there\b`,
    String.raw`\b(?:does|do|did) (?:it|this|that|they|these|those|the [\w-]+) (?:have|has|use|come with)\b`,
    String.raw`\btraces?\b`,
    String.raw`\bcross[- ]contact\b`,
    // Chinese
    '过敏', '不要', '不能', '不含', '不加', '别放', '别加', '去掉', '免', '没有', '有没有', '含有', '是否', '忌口', '有.{0,10}吗',
    // Japanese
    'アレルギー', '抜き', 'ぬき', 'なし', '無し', '入れないで', '除いて', '食べられ', '入って(?:い)?ますか', '含まれ', '使って(?:い)?ますか', '使われ', '避け', 'ダメ', 'だめ', '不使用', '控え',
  ].join('|'),
  'i',
);

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
 */
export function unsafeMention(texts: readonly string[], hazards: readonly Hazard[]): string | null {
  if (hazards.length === 0) return null;
  const joined = texts.join('\n');
  const hit = hazards.find((hazard) => hazard.pattern.test(joined));
  if (!hit) return null;
  return SAFETY_CONTEXT.test(joined) ? null : hit.label;
}
