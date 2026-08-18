export function JobsPage() {
  return (
    <div className="layout">
      <div className="stream">
        <div className="logline">$ meister status</div>
        <div className="logline">
          <b>queue:</b> this UI is a read-only tail — start work with <b>meister review</b>
        </div>
        <div className="empty">
          No jobs yet. In a repo run <code>meister review</code>.
          <br />
          Jobs appear here only after the CLI POSTs them.
        </div>
      </div>
      <aside className="rail">
        <h3>Rules (edit in UI)</h3>
        <div className="rule">
          <span className="rn">—</span>
          <br />
          <span className="rk">CRUD lands in a later PR</span>
        </div>
        <h3>Context notes (/context)</h3>
        <div className="ctx">User notes will list here.</div>
        <h3>Learnings inbox</h3>
        <div className="neverapply">nothing auto-applies — accept writes, dismiss deletes</div>
      </aside>
    </div>
  );
}
