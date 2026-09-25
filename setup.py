"""Compatibility shim for the editable-install command shipped with older pip."""

from setuptools import find_packages, setup


setup(
    name="voxlocal-remote-scribe-host",
    version="0.1.0",
    description="ZDR Remote Scribe host and local agent API",
    packages=find_packages(include=["agent", "agent.*"]),
    python_requires=">=3.11",
    entry_points={"console_scripts": ["voxlocal-agent=agent.voxlocal_agent_api:main"]},
)
