defmodule Hermit.Web do
  use Plug.Router
  require EEx

  @base_url  Hermit.Config.base_url
  @host      Hermit.Config.host
  @sink_port Hermit.Config.sink_port

  plug :match
  plug :dispatch

  EEx.function_from_file(:defp, :index_template, "./web/index.html", [:host, :port, :base_url])
  EEx.function_from_file(:defp, :pipe_template, "./web/pipe_view.html", [:sse_url])

  get "/" do
    conn
    |> put_resp_header("content-type", "text/html")
    |> send_resp(200, index_template(@host, @sink_port, @base_url))
  end

  # Plain text
  get "/p/:pipe_id" do
    conn |> stream_response(pipe_id, :plain)
  end

  get "/v/:pipe_id" do
    sse_url = "#{@base_url}/stream/#{pipe_id}"

    conn
    |> put_resp_header("content-type", "text/html")
    |> send_resp(200, pipe_template(sse_url))
  end

  get "/stream/:pipe_id" do
    conn |> stream_response(pipe_id, :sse)
  end

  defp stream_response(conn, pipe_id, resp_kind) do
    content_type =
      case resp_kind do
        :sse -> "text/event-stream"
        :plain -> "text/plain"
      end

    if Hermit.Plumber.valid_pipe?(pipe_id) do
      # Register our process as a pipe listener
      Hermit.Plumber.add_pipe_listener(pipe_id, self())

      conn
      |> put_resp_header("content-type", content_type)
      |> send_chunked(200)
      |> send_replay(pipe_id, resp_kind)
      |> listen_loop(resp_kind)
    else
      send_resp(conn, 404, "fo oh fo")
    end
  end

  defp send_replay(conn, pipe_id, resp_kind) do
    pipe_id
    |> Hermit.Plumber.get_pipe_file
    |> File.stream!([], 2048)
    |> Enum.map(&(format_chunk(&1, :input, resp_kind)))
    |> Enum.into(conn)
  end

  defp format_chunk(bytes, _event, :plain), do: bytes
  defp format_chunk(bytes, event, :sse) do
    encoded = Base.encode64(bytes)
    "event: #{event}\ndata: #{encoded}\n\n"
  end

  defp write_chunk(conn, msg) do
    {:ok, conn} = chunk(conn, msg)
    conn
  end

  defp listen_loop(conn, resp_kind) do
    receive do
      { :pipe_activity, msg } ->
        conn
        |> write_chunk(format_chunk(msg, :input, resp_kind))
        |> listen_loop(resp_kind)

      { :closed } ->
        conn
        |> write_chunk(format_chunk("", :closed, resp_kind))
    end
  end

  match _ do
    send_resp(conn, 404, "fo oh fo")
  end
end
