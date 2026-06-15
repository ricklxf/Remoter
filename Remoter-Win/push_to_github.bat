@echo off
echo ========================================
echo Push Remoter-Win to GitHub
echo ========================================
echo.

echo Step 1: Configure git user (if not already configured)
git config --global user.name "ricklxf"
git config --global user.email "ricklxf@example.com"

echo.
echo Step 2: Add GitHub remote repository
echo Please make sure https://github.com/ricklxf/Remoter repository exists
echo.
pause

git remote add origin https://github.com/ricklxf/Remoter.git

echo.
echo Step 3: Create Remoter-Win directory in the repo
echo Note: This will push the current code to a new branch
echo You may need to manually create the Remoter-Win folder on GitHub
echo.
pause

echo.
echo Step 4: Push to GitHub
echo If the repository is empty, use: git push -u origin master
echo If the repository has other folders, you may need to:
echo   1. Create a new branch
echo   2. Or push to a subdirectory (requires manual operation)
echo.
echo Trying to push to master branch...
git push -u origin master

echo.
if %errorlevel% neq 0 (
    echo.
    echo Push failed! You may need to:
    echo 1. Create the repository on GitHub first
    echo 2. Use SSH instead of HTTPS
    echo 3. Push to a different branch
    echo.
    echo Alternative: Use the following commands manually:
    echo   git remote add origin https://github.com/ricklxf/Remoter.git
    echo   git pull origin main --allow-unrelated-histories
    echo   git push -u origin main
)

echo.
echo ========================================
echo Done!
echo ========================================
pause
