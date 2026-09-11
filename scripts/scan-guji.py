#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描本地古籍目录，生成站点数据。

生成：
  data/catalog.json              目录（分类/书/章节清单，不含正文）
  data/books/<书名>/原文/*.md    直接拷贝的原文 Markdown
  data/books/<书名>/译文/*.md    直接拷贝的译文 Markdown（如有）

前端直接加载 Markdown 并渲染，换行等格式以源文件为准。
拷贝的 Markdown 行尾统一为 LF；catalog.json 与 排序.txt 写成 UTF-8（带 BOM）+ LF。

用法：
  python3 scripts/scan-guji.py [-g 古籍目录]

排序与收录：编辑仓库根目录的 排序.txt 后重跑本脚本即可。
  [分类]     -> 分类顺序（同时是分类白名单）
  [分类名]   -> 该分类下要收录的书籍及其顺序（书的白名单）
  [书名]     -> 该书的篇章顺序（多篇章书籍自动生成，可手动调整）
  只有列在 [分类] 与 [分类名] 区域里的分类/书籍才会进 catalog.json 并显示在网站上。
  未收录的分类/书籍，其区段会原样保留在 排序.txt 里但不起作用；重新列入后自动生效，
  因此不必为“暂时不收录”而删掉篇章顺序。
"""

import argparse
import datetime
import os
import re
import shutil
import sys

MAX_SORT_KEY = 2147483647

DIGITS = {'零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
          '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
UNITS = {'十': 10, '百': 100, '千': 1000}

HEADER_LINES = [
    '# 玄门正典 · 排序文件',
    '# 修改方法：调整下面各行的先后顺序，保存后重新运行 scripts/scan-guji.py 并提交推送即可生效',
    '# [分类] 区域：分类顺序（同时是分类白名单）',
    '# [分类名] 区域：该分类下要收录的书籍及其顺序（书的白名单）',
    '# [书名] 区域：该书的篇章顺序（仅多篇章书籍有此区域）',
    '# 本文件是收录白名单：只有列在 [分类] 与 [分类名] 区域里的分类/书籍才会显示在网站上',
    '# 新增书籍：先放进古籍目录，再把书名写进对应分类区域，重跑本脚本即可收录',
    '# 未收录的分类/书籍：其区段会原样保留在文件末尾但不起作用，重新列入后自动生效',
    '# 篇章顺序：未列入的篇章会自动追加到对应区域末尾，可再手动调整位置',
]

CHAPTER_MARKER = '# ======= 篇章顺序 ======='


# ---------------------------------------------------------------- 名称与排序

def slug(name):
    """去掉前导数字编号，如 "01_太上老君说常清静经" -> "太上老君说常清静经"。"""
    return re.sub(r'^\d+[-_]', '', name)


def chinese_number(text):
    """把中文数字转成整数；无法解析时返回 -1。"""
    total = 0
    number = 0
    for char in text:
        if char in DIGITS:
            number = DIGITS[char]
        elif char in UNITS:
            if number == 0:
                number = 1
            total += number * UNITS[char]
            number = 0
        else:
            return -1
    return total + number


def sort_key(name):
    """默认排序键：前导数字 > "第N" > 前导中文数字 > 最后。"""
    base = os.path.splitext(name)[0]

    match = re.match(r'^(\d+)', base)
    if match:
        return int(match.group(1))

    match = re.search(r'第([零一二两三四五六七八九十百千]+|\d+)', base)
    if match:
        token = match.group(1)
        if token.isdigit():
            return int(token)
        value = chinese_number(token)
        if value >= 0:
            return value

    match = re.match(r'^[卷篇]?([零一二两三四五六七八九十百千]+)', base)
    if match:
        value = chinese_number(match.group(1))
        if value >= 0:
            return value

    return MAX_SORT_KEY


def list_dirs(path):
    names = [name for name in os.listdir(path) if os.path.isdir(os.path.join(path, name))]
    names.sort(key=lambda name: (sort_key(name), name))
    return names


def order_index(name, order_list):
    """name 在手动顺序里的位置；未列入的排在最后。"""
    try:
        return order_list.index(name)
    except ValueError:
        return 10000


# ---------------------------------------------------------------- 文件读写

def read_text(path):
    with open(path, 'rb') as handle:
        return handle.read().decode('utf-8-sig')


def write_text(path, lines):
    """UTF-8（带 BOM）+ LF，与仓库既有文件保持一致。"""
    data = '\n'.join(lines) + '\n'
    with open(path, 'wb') as handle:
        handle.write(b'\xef\xbb\xbf' + data.encode('utf-8'))


def parse_order_file(path):
    """解析 排序.txt，返回 (区段内容, 区段出现顺序)。"""
    sections = {}
    section_order = []
    if not os.path.exists(path):
        return sections, section_order

    section = None
    for raw in re.split(r'\r?\n', read_text(path)):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        match = re.match(r'^\[(.+)\]$', line)
        if match:
            section = match.group(1).strip()
            if section not in sections:
                sections[section] = []
                section_order.append(section)
            continue
        if section is not None:
            sections[section].append(line)
    return sections, section_order


def normalize_line_endings(root):
    """把拷贝出来的 Markdown 行尾统一为 LF（源文件多为 CRLF）。"""
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith('.md'):
                continue
            path = os.path.join(dirpath, name)
            with open(path, 'rb') as handle:
                data = handle.read()
            if b'\r\n' in data:
                with open(path, 'wb') as handle:
                    handle.write(data.replace(b'\r\n', b'\n'))


# ------------------------------------------------- catalog.json（Windows PowerShell 5.1 ConvertTo-Json 风格）

JSON_ESCAPES = {
    '\\': '\\\\', '"': '\\"', '\b': '\\b', '\f': '\\f', '\n': '\\n',
    '\r': '\\r', '\t': '\\t', '<': '\\u003c', '>': '\\u003e',
    '&': '\\u0026', "'": '\\u0027',
}


def json_string(value):
    out = []
    for char in value:
        if char in JSON_ESCAPES:
            out.append(JSON_ESCAPES[char])
        elif ord(char) < 0x20:
            out.append('\\u%04x' % ord(char))
        else:
            out.append(char)
    return '"' + ''.join(out) + '"'


def json_scalar(value):
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if value is None:
        return 'null'
    if isinstance(value, int):
        return str(value)
    return json_string(str(value))


def render_catalog(catalog):
    """按 PowerShell 5.1 ConvertTo-Json 的缩进习惯输出（键值间两个空格、数组另加一层缩进）。"""
    lines = []

    def render_object(obj, indent):
        lines.append(' ' * indent + '{')
        items = list(obj.items())
        for index, (key, value) in enumerate(items):
            prefix = json_string(str(key)) + ':  '
            line_indent = indent + 4
            if isinstance(value, list):
                lines.append(' ' * line_indent + prefix + '[')
                item_indent = line_indent + len(str(key)) + 9
                for position, item in enumerate(value):
                    render_object(item, item_indent)
                    if position != len(value) - 1:
                        lines[-1] += ','
                lines.append(' ' * (item_indent - 4) + ']' + (',' if index != len(items) - 1 else ''))
            else:
                lines.append(' ' * line_indent + prefix + json_scalar(value) +
                             (',' if index != len(items) - 1 else ''))
        lines.append(' ' * indent + '}')

    render_object(catalog, 0)
    return lines


# ---------------------------------------------------------------- 主流程

def resolve_guji_root(explicit, repo_root):
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get('GUJI_ROOT'):
        candidates.append(os.environ['GUJI_ROOT'])
    candidates.extend([
        os.path.join(repo_root, '..', 'ancient-text'),
        os.path.join(repo_root, '..', '古籍'),
        os.path.join(repo_root, '..', '..', '古籍'),
        os.path.join(repo_root, '..', '..', '古文整理本地', '古籍'),
    ])
    for candidate in candidates:
        path = os.path.abspath(candidate)
        if os.path.isdir(path):
            return path
    raise SystemExit('找不到古籍目录，请用 --guji-root 指定。已尝试：\n  ' +
                     '\n  '.join(os.path.abspath(c) for c in candidates))


def scan(guji_root, books_dir, order_path):
    """扫描古籍目录并拷贝 Markdown，返回 (categories, all_book_ids, all_book_titles, all_cat_names,
    sections, section_order, bootstrap)。"""
    sections, section_order = parse_order_file(order_path)
    bootstrap = not os.path.exists(order_path)
    if bootstrap:
        print('未找到排序文件，按“全部收录”生成: %s' % order_path)
    else:
        print('已读取排序文件: %d 个区域' % len(section_order))

    user_cat_order = sections.get('分类', [])
    os.makedirs(books_dir, exist_ok=True)

    categories = []
    all_book_ids = {}
    all_book_titles = set()
    all_cat_names = set()

    for category_name in list_dirs(guji_root):
        category_path = os.path.join(guji_root, category_name)
        category_id = slug(category_name)
        all_cat_names.add(category_name)
        category_listed = bootstrap or category_name in user_cat_order
        if not category_listed:
            print('分类未列入排序文件，不收录: %s' % category_name)

        books = []
        for book_name in list_dirs(category_path):
            book_path = os.path.join(category_path, book_name)
            book_id = slug(book_name).replace('.', '-')
            book_title = slug(book_name)
            source_dir = os.path.join(book_path, '原文')
            trans_dir = os.path.join(book_path, '译文')

            if not os.path.isdir(source_dir):
                continue
            all_book_ids[book_id] = True
            all_book_titles.add(book_title)

            # 白名单：分类与书籍都要列在 排序.txt 里才收录
            book_list = sections.get(category_name) or []
            if not category_listed:
                continue
            if not bootstrap and book_title not in book_list:
                print('未列入排序文件，不收录: %s' % book_title)
                continue

            source_files = sorted((name for name in os.listdir(source_dir) if name.endswith('.md')),
                                  key=lambda name: (sort_key(name), name))
            if not source_files:
                continue

            # 重建输出目录并拷贝 Markdown
            out_book_dir = os.path.join(books_dir, book_id)
            if os.path.isdir(out_book_dir):
                shutil.rmtree(out_book_dir)
            out_source = os.path.join(out_book_dir, '原文')
            out_trans = os.path.join(out_book_dir, '译文')
            os.makedirs(out_source, exist_ok=True)

            chapters = []
            for name in source_files:
                shutil.copy2(os.path.join(source_dir, name), os.path.join(out_source, name))

                trans_file = os.path.join(trans_dir, name)
                has_trans = os.path.isfile(trans_file)
                if has_trans:
                    os.makedirs(out_trans, exist_ok=True)
                    shutil.copy2(trans_file, os.path.join(out_trans, name))

                chapter_title = slug(os.path.splitext(name)[0])
                chapters.append({
                    'id': chapter_title.replace('.', '-'),
                    'title': chapter_title,
                    'file': name,
                    'hasTrans': has_trans,
                })

            # 篇章排序：优先 [书名] 区域，未列入的按默认规则排在后面
            chapter_order = sections.get(book_title) or []
            chapters.sort(key=lambda chapter: (order_index(chapter['title'], chapter_order),
                                               sort_key(chapter['file'])))

            books.append({
                'id': book_id,
                'title': book_title,
                'category': category_name,
                'categoryId': category_id,
                'chapterCount': len(chapters),
                'chapters': chapters,
            })

        if books:
            order_list = sections.get(category_name) or []
            books.sort(key=lambda book: (order_index(book['title'], order_list), sort_key(book['title'])))
            categories.append({
                'id': category_id,
                'name': category_name,
                'books': books,
            })

    categories.sort(key=lambda category: (order_index(category['name'], user_cat_order),
                                          sort_key(category['name'])))

    return (categories, all_book_ids, all_book_titles, all_cat_names,
            sections, section_order, bootstrap)


def write_order_file(path, categories, sections, section_order, all_cat_names, all_book_titles):
    """回写 排序.txt：已收录的按计算出的顺序写；未收录的区段原样保留但不起作用。"""
    included_categories = {category['name'] for category in categories}
    included_books = {book['title'] for category in categories for book in category['books']}

    lines = list(HEADER_LINES)
    lines.append('')
    lines.append('[分类]')
    for category in categories:
        lines.append(category['name'])

    for category in categories:
        lines.append('')
        lines.append('[%s]' % category['name'])
        for book in category['books']:
            lines.append(book['title'])

    # 未收录的分类：区段保留（重新列入 [分类] 后自动生效）
    for key in section_order:
        if key in all_cat_names and key not in included_categories and key not in all_book_titles:
            lines.append('')
            lines.append('[%s]' % key)
            lines.extend(sections[key])

    lines.append('')
    lines.append(CHAPTER_MARKER)

    for category in categories:
        for book in category['books']:
            if book['chapterCount'] <= 1:
                continue
            lines.append('')
            lines.append('[%s]' % book['title'])
            for chapter in book['chapters']:
                lines.append(chapter['title'])

    # 未收录书籍的篇章顺序：区段保留（重新收录后自动生效）
    for key in section_order:
        if key in all_book_titles and key not in included_books and key not in all_cat_names:
            lines.append('')
            lines.append('[%s]' % key)
            lines.extend(sections[key])

    write_text(path, lines)
    print('已更新排序文件: %s' % path)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='扫描古籍目录，生成 data/catalog.json 与 data/books。')
    parser.add_argument('-g', '--guji-root', help='古籍目录；默认自动探测')
    parser.add_argument('-r', '--repo-root', help='仓库根目录；默认为本脚本所在目录的上级')
    args = parser.parse_args(argv)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(args.repo_root or os.path.join(script_dir, '..'))
    guji_root = resolve_guji_root(args.guji_root, repo_root)

    data_dir = os.path.join(repo_root, 'data')
    books_dir = os.path.join(data_dir, 'books')
    catalog_file = os.path.join(data_dir, 'catalog.json')
    order_file = os.path.join(repo_root, '排序.txt')

    print('GujiRoot: %s' % guji_root)
    print('OutputDir: %s' % data_dir)
    print('OrderFile: %s' % order_file)

    (categories, all_book_ids, all_book_titles, all_cat_names,
     sections, section_order, _bootstrap) = scan(guji_root, books_dir, order_file)

    normalize_line_endings(books_dir)

    write_order_file(order_file, categories, sections, section_order,
                     all_cat_names, all_book_titles)

    # 清理过期数据：只清理源目录里已不存在的书；未收录的书保留在 data/books
    for name in os.listdir(books_dir):
        path = os.path.join(books_dir, name)
        if os.path.isdir(path) and name not in all_book_ids:
            print('清理过期数据: %s' % name)
            shutil.rmtree(path)

    catalog = {
        'generatedAt': datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
        'totalCategories': len(categories),
        'totalBooks': sum(len(category['books']) for category in categories),
        'categories': categories,
    }
    write_text(catalog_file, render_catalog(catalog))

    included_ids = {book['id'] for category in categories for book in category['books']}
    print('已生成目录: %s' % catalog_file)
    print('已拷贝书籍 Markdown: %s (%d 本)' % (books_dir, len(included_ids)))
    for category in categories:
        print('  %s: %d 本' % (category['name'], len(category['books'])))

    return 0


if __name__ == '__main__':
    sys.exit(main())
