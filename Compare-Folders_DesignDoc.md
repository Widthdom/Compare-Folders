
# Compare-Folders.ps1 設計書

## 概要

このスクリプトは、2つのフォルダを比較し、ファイルの差分（追加、削除、変更）を出力します。特に、.NETベースのデプロイメントにおいて、リリース間の差異を検証するために有用です。

---

## 必要要件

- `.NET IL Disassembler (dotnet-ildasm)` がインストールされており、`PATH` に通っている必要があります。
  - インストール方法（PowerShell）：
    ```bash
    dotnet tool install --global dotnet-ildasm
    ```

---

## 動作仕様

| 拡張子の種類                     | 比較方法                           | 説明                                                         |
|----------------------------------|------------------------------------|--------------------------------------------------------------|
| `.pdb`, `.cache`, `.log`         | 無視                               | 差分の対象外とみなされる                                     |
| `.dll`, `.exe`                   | ILコードの比較                     | `dotnet-ildasm` を使って逆アセンブル後に中身を比較           |
| `.ps1`, `.bat`, `.md`, `.txt`    | テキスト比較                       | プレーンテキストとしてファイル内容を比較                     |
| `.json`, `.csproj`, `.sln`, `.cs`, `.config` | テキスト比較              | 同上                                                         |
| その他のファイル                 | MD5ハッシュ比較                    | バイナリとして内容を比較                                     |

---

## パラメータ

| パラメータ名 | 説明                              | デフォルト値                |
|--------------|-----------------------------------|-----------------------------|
| `-Old`       | 比較対象の旧フォルダパス          | `C:\ModuleSet\Old`        |
| `-New`       | 比較対象の新フォルダパス          | `C:\ModuleSet\New`        |

---

## 出力内容

- `diff_report.md` ファイルが、スクリプトと同じフォルダに生成されます。
- 内容は以下の3つのカテゴリに分類されます：
  - `Unchanged Files`：新旧両方のフォルダにあり、中身も同一（IncludeSameがtrueのときのみ）
  - `Added Files`：新しいフォルダにしか存在しないファイル
  - `Removed Files`：旧フォルダにしか存在しないファイル
  - `Modified Files`：新旧両方のフォルダに存在するが中身が異なるファイル

---

## 主な関数

### Write-Log

ログファイル (`diff_report.md`) とコンソールの両方にメッセージを出力するユーティリティ関数。

- 引数: `$text`（出力する文字列）
- 動作: UTF-8 でログファイルに追記し、同時に `Write-Output` でコンソールにも表示する。


### Confirm-Folder

指定されたフォルダパスに対して以下の検証を行い、問題があれば例外を発生させる。

- 存在確認：`Test-Path` で存在チェック。
- ディレクトリ確認：`Get-Item` でフォルダかどうか確認。
- 読み取り確認：`Get-ChildItem` を再帰的に走査し、アクセスできるか検証。

- 引数: `$path`（確認対象のパス）
- エラー時の動作: `throw` により処理を中断し、明確なメッセージを出力。


### Get-FileHashes

指定フォルダ配下のすべてのファイルについて、**相対パス**と**MD5ハッシュ**を取得し、ハッシュマップとして返す。

- 引数:
  - `$basePath`: 走査対象のルートディレクトリ
  - `$FileHashProgressInterval`: 処理ファイル数の進捗表示の間隔（省略可）

- 動作:
  - `Get-ChildItem` で再帰的にファイル一覧を取得。
  - `Get-FileHash` で各ファイルのMD5を取得。
  - 相対パスをキーとしたハッシュマップを構築して返す。


### Compare-FileContents

2つのファイルの内容を、拡張子に応じた方法で比較する。

- 比較方法は以下の通り自動判別される：
  - `.pdb`, `.cache`, `.log`: 無視（常に一致とみなす）
  - `.ps1`, `.bat`, `.txt`, `.json`, `.csproj`, など: テキストとして比較
  - `.dll`, `.exe`: `dotnet-ildasm` を使って ILコードを比較
  - その他: MD5ハッシュで比較

- 引数:
  - `$oldInfo`, `$newInfo`: 各ファイルの `Hash` および `FullPath` を持つハッシュ情報
  - `$extension`: ファイルの拡張子

- 戻り値: 内容が同一なら `$true`、異なれば `$false`


### Compare-Folders

このスクリプトのメイン処理。2つのフォルダ内のファイル構成と内容を比較し、追加・削除・変更されたファイルをログに出力する。

- 動作手順:
  1. `Confirm-Folder` で対象フォルダを検証
  2. `Get-FileHashes` で両フォルダのファイル情報を取得
  3. ファイルリストを比較し、以下に分類：
     - `Unchanged Files`: 新旧両方のフォルダにあり、中身も同一（IncludeSameがtrueのときのみ）
     - `Added Files`: 新フォルダのみに存在
     - `Removed Files`: 旧フォルダのみに存在
     - `Modified Files`: 新旧両方のフォルダにあるが中身が異なる
  4. 各結果を `Write-Log` によって `diff_report.md` に出力

- 戻り値: なし（ログ出力のみ）

---

## 使用例

```powershell
.\Compare-Folders.ps1 -Old "C:\OldVersion" -New "C:\NewVersion"
```

---

## オプション

- `-Old`  
  比較対象の旧フォルダパス。

- `-New`  
  比較対象の新フォルダパス。

- `-IncludeSame`  
  （ブーリアン）true の場合、レポートに両方のフォルダに同一のファイルも含める。  
  false の場合、差分のみがレポートされる。

## 使用例

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "Compare-Folders.ps1" -Old "D:\Old" -New "D:\New" -IncludeSame:true
```

## レポート出力

- `IncludeSame` が true の場合、レポートには以下が表示される：
  - = 両方に存在し、内容も同一のファイル
  - \- Old のみのファイル
  - \+ New のみのファイル
  - \* 両方に存在し、内容が異なるファイル

- `IncludeSame` が false の場合、レポートには差分のみが表示される。
  - \- Old のみのファイル
  - \+ New のみのファイル
  - \* 両方に存在し、内容が異なるファイル

---

## 補足事項

- ILコード比較は、わずかなビルド差異も検出対象になるため、リリースビルド間の比較に注意が必要です。
- diff_report.md は毎回スクリプトの実行時に上書きされるため、事前に削除する必要はありません。
- 比較はファイルパスが同一のものに対して行われます（ファイル名・フォルダ構造が一致している必要あり）。

---

## SuppressIldasmAttribute への対応（dotnet-ildasm 実行時）

- `.dll` や `.exe` の比較では、`dotnet-ildasm` を使って ILコードに変換し、内容の一致を判定します。
- ただし、対象のアセンブリに `[SuppressIldasm]` 属性が付与されている場合、逆アセンブルがブロックされ、`dotnet-ildasm` が失敗することがあります。

### 対応方法：

- スクリプトは `dotnet-ildasm` 実行時にエラーをキャッチし、以下のような警告を出力します：

```
WARNING: Cannot disassemble 'C:\ModuleSet\New\Secure.dll'. SuppressIldasm may be applied.
```

- このようなファイルは「内容不一致」として扱われます（中身が確認できないため）。

### 注意：

- 本当にコードが異なるかどうかは、このメッセージを見た上で判断してください。
- リリース用のアセンブリに `[SuppressIldasm]` を付ける場合、比較用に「検査専用ビルド」を用意するのが理想です。
