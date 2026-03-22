---
name: task-kanban
description: |
  プロジェクトのタスクを TASKS.md で看板管理するスキルです。
  gh-task CLI を使ってタスクの追加・進行・完了を自律的に行います。
  カラムはハードコードではなく TASKS.md から動的に読み取ります。
  Use when: タスク管理, TODO管理, 作業計画, 進捗管理, タスク追加, タスク完了,
  "何をやるべき", "次のタスク", "タスクを追加", "完了にして", kanban, task management
---

# task-kanban

プロジェクトの TASKS.md を看板ボードとして管理する。

## CLI リファレンス

```
gh task add <title> [-s status]            # タスク追加（デフォルト: 最初のカラム）
gh task ls                                 # 看板ボード表示
gh task move <id> <status>                 # カラム移動
gh task edit <id> <new-title>              # タイトル変更
gh task rm <id>                            # 削除
gh task columns                            # カラム一覧
gh task pull <owner> <project-number>      # GitHub Project → TASKS.md
gh task push <owner> <project-number>      # TASKS.md → GitHub Project
```

## ワークフロー

1. **初期化**: `gh task pull <owner> <num>` でプロジェクトのカラム構成を取得
2. **タスク分解**: ユーザーの依頼を受けたら `gh task add` で個別タスクに分解する
3. **カラム移動**: `gh task move <id> <status>` でステータスを変更
4. **現状確認**: `gh task ls` で看板を表示し、ユーザーに進捗を伝える
5. **同期**: `gh task push <owner> <num>` でプロジェクトに反映

## 規約

- TASKS.md はプロジェクトルートに配置される（git管理対象）
- カラムは TASKS.md の `## ` ヘッダーから動的に読み取られる（ハードコードなし）
- `gh task pull` でGitHub Projectのカラム構成をそのまま取得可能
- 1タスク = 1つの具体的なアクション（大きすぎるものは分割する）
- タスクを追加する際は、既存の技術負債や改善余地も洗い出してタスク化する

## TASKS.md フォーマット

```markdown
# Tasks

## Todo

- [ ] タスクタイトル <!-- id:1 -->

## In Progress

- [ ] 進行中のタスク <!-- id:2 -->

## Done

- [x] 完了したタスク <!-- id:3 -->
```
