---
name: task-kanban
description: |
  プロジェクトのタスクを TASKS.md で看板管理するスキルです。
  gh-task CLI を使ってタスクの追加・進行・完了を自律的に行います。
  Use when: タスク管理, TODO管理, 作業計画, 進捗管理, タスク追加, タスク完了,
  "何をやるべき", "次のタスク", "タスクを追加", "完了にして", kanban, task management
---

# task-kanban

プロジェクトの TASKS.md を看板ボードとして管理する。

## CLI リファレンス

```
gh task add <title> [-s todo|doing|done]   # タスク追加（デフォルト: todo）
gh task ls                                 # 看板ボード表示
gh task start <id>                         # doing に移動
gh task done <id>                          # done に移動
gh task move <id> <status>                 # 任意のステータスに移動
gh task edit <id> <new-title>              # タイトル変更
gh task rm <id>                            # 削除
```

## ワークフロー

1. **タスク分解**: ユーザーの依頼を受けたら `gh task add` で個別タスクに分解する
2. **着手宣言**: 作業開始時に `gh task start <id>` で doing に移動
3. **完了報告**: 作業完了時に `gh task done <id>` で done に移動
4. **現状確認**: `gh task ls` で看板を表示し、ユーザーに進捗を伝える

## 規約

- TASKS.md はプロジェクトルートに配置される（git管理対象）
- 1タスク = 1つの具体的なアクション（大きすぎるものは分割する）
- doing は同時に3つまで（WIP制限）
- done になったタスクは次のリリースまで残す
- タスクを追加する際は、既存の技術負債や改善余地も洗い出してタスク化する

## TASKS.md フォーマット

```markdown
# Tasks

## TODO

- [ ] タスクタイトル <!-- id:1 -->

## DOING

- [ ] 進行中のタスク <!-- id:2 -->

## DONE

- [x] 完了したタスク <!-- id:3 -->
```
