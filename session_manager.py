from contextlib import contextmanager
from tasks import get_session as tasks_get_session

@contextmanager
def managed_session():
    session = None
    try:
        session = tasks_get_session()
        yield session
    except Exception:
        if session:
            session.rollback()
        raise
    finally:
        if session:
            session.close()
