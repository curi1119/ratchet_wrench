defmodule RatchetWrenchTest do
  use ExUnit.Case
  doctest RatchetWrench

  describe "Operation DDL" do
    setup do
      System.put_env("RATCHET_WRENCH_TOKEN_SCOPE", "https://www.googleapis.com/auth/spanner.admin")
      on_exit fn ->
        System.put_env("RATCHET_WRENCH_TOKEN_SCOPE", "https://www.googleapis.com/auth/spanner.data")
      end
    end

    test "update ddl" do
      ddl_singer = "CREATE TABLE data (
                     id STRING(MAX) NOT NULL,
                     string STRING(MAX),
                     bool BOOL,
                     int INT64,
                     float FLOAT64,
                     time_stamp TIMESTAMP,
                     date DATE,
                   ) PRIMARY KEY(id)"

      ddl_data = "CREATE TABLE singers (
                   id STRING(1024) NOT NULL,
                   first_name STRING(1024),
                   last_name STRING(1024),
                   birth_date DATE,
                   created_at TIMESTAMP,
                   updated_at TIMESTAMP,
                   ) PRIMARY KEY(id)"

      ddl_list = [ddl_singer, ddl_data]
      {:ok, operation} = RatchetWrench.update_ddl(ddl_list)
      assert operation.error == nil
    end

    test "update ddl, error syntax" do
      ddl_error = "Error Syntax DDL"
      ddl_list = [ddl_error]
      {:error, reason} = RatchetWrench.update_ddl(ddl_list)
      assert reason["error"]["code"] == 400
      assert reason["error"]["message"] == "Error parsing Spanner DDL statement: Error Syntax DDL : Syntax error on line 1, column 1: Encountered 'Error' while parsing: ddl_statement"
    end
  end

  test "get token" do
    assert RatchetWrench.token().token !=  nil
    assert RatchetWrench.token().expires > :os.system_time(:second)
  end

  test "get connection" do
    assert RatchetWrench.connection(RatchetWrench.token) != nil
  end

  test "get session/delete session" do
    token = RatchetWrench.token
    connection = RatchetWrench.connection(token)
    session = RatchetWrench.create_session(connection)
    assert session != nil
    {:ok, _} = RatchetWrench.delete_session(connection, session)
  end

  test "Connection check CloudSpanner" do
    {:ok, result_set} = RatchetWrench.select_execute_sql("SELECT 1")
    assert result_set != nil
    assert result_set.rows == [["1"]]
  end

  test "execute SELECT SQL" do
    {:ok, result_set} = RatchetWrench.select_execute_sql("SELECT * FROM singers")
    assert result_set != nil

    [id, first_name, last_name | _] = List.first(result_set.rows)
    assert id == "1"
    assert first_name == "Marc"
    assert last_name == "Richards"
    [id, first_name, last_name | _] = List.last(result_set.rows)
    assert id == "3"
    assert first_name == "Kena"
    assert last_name == nil
  end

  test "SQL INSERT/UPDATE/DELETE" do
    {:ok, result_set} = RatchetWrench.select_execute_sql("SELECT * FROM singers")
    before_rows_count = Enum.count(result_set.rows)

    {:ok, result_set} = RatchetWrench.execute_sql("INSERT INTO singers(id, first_name, last_name) VALUES('2', 'Catalina', 'Smith')")
    assert result_set != nil

    result_set = RatchetWrench.sql("SELECT * FROM singers")
    assert result_set != nil

    Enum.with_index(result_set.rows, 1)
    |> Enum.map(fn({raw_list, id}) ->
      assert List.first(raw_list) == "#{id}"
    end)

    {:ok, result_set} = RatchetWrench.execute_sql("DELETE FROM singers WHERE id = '2'")
    assert result_set != nil
    assert result_set.stats.rowCountExact == "1"


    {:ok, result_set} = RatchetWrench.select_execute_sql("SELECT * FROM singers")
    after_rows_count = Enum.count(result_set.rows)

    assert before_rows_count == after_rows_count
  end

  test "SQL SELECT/SELECT in Transaction" do
    sql = "SELECT * FROM singers"

    sql_list = [sql, sql]

    result_set_list = RatchetWrench.transaction_execute_sql(sql_list)
    assert result_set_list != nil

    result_set = List.first(result_set_list)

    [id, first_name, last_name | _] = List.first(result_set.rows)
    assert id == "1"
    assert first_name == "Marc"
    assert last_name == "Richards"
    [id, first_name, last_name | _] = List.last(result_set.rows)
    assert id == "3"
    assert first_name == "Kena"
    assert last_name == nil

    result_set = List.last(result_set_list)
    [id, first_name, last_name | _] = List.first(result_set.rows)
    assert id == "1"
    assert first_name == "Marc"
    assert last_name == "Richards"
    [id, first_name, last_name | _] = List.last(result_set.rows)
    assert id == "3"
    assert first_name == "Kena"
    assert last_name == nil
  end

  test "SQL SELECT/INSERT/UPDATE/DELETE in Transaction" do
    select_sql = "SELECT * FROM singers"
    insert_sql = "INSERT INTO singers(id, first_name, last_name) VALUES('2','Catalina', 'Smith')"
    update_sql = "UPDATE singers SET first_name = \"Cat\" WHERE id = '2'"
    delete_sql = "DELETE FROM singers WHERE id = '2'"

    sql_list = [select_sql, insert_sql, select_sql, update_sql, select_sql, delete_sql, select_sql]

    result_set_list = RatchetWrench.transaction_execute_sql(sql_list)
    assert result_set_list != nil

    [select_result_set | tail_set_list] = result_set_list
    assert select_result_set != nil
    assert Enum.count(select_result_set.rows) == 2

    [insert_result_set | tail_set_list] = tail_set_list
    assert insert_result_set != nil
    assert insert_result_set.stats.rowCountExact == "1"

    [select_result_set | tail_set_list] = tail_set_list
    assert select_result_set != nil
    assert Enum.count(select_result_set.rows) == 3

    [update_result_set | tail_set_list] = tail_set_list
    assert update_result_set != nil
    assert update_result_set.stats.rowCountExact == "1"

    [select_result_set | tail_set_list] = tail_set_list
    assert select_result_set != nil
    assert Enum.count(select_result_set.rows) == 3

    {update_raw, _} = List.pop_at(select_result_set.rows, 1)
    [id, first_name, last_name | _] = update_raw
    assert id == "2"
    assert first_name == "Cat"
    assert last_name == "Smith"

    [delete_result_set | tail_set_list] = tail_set_list
    assert delete_result_set.stats.rowCountExact == "1"

    [select_result_set | tail_set_list] = tail_set_list
    assert select_result_set != nil

    [id, first_name, last_name | _] = List.first(select_result_set.rows)
    assert id == "1"
    assert first_name == "Marc"
    assert last_name == "Richards"
    [id, first_name, last_name | _] = List.last(select_result_set.rows)
    assert id == "3"
    assert first_name == "Kena"
    assert last_name == nil

    assert tail_set_list == []
  end
end
