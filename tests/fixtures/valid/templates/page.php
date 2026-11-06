<!DOCTYPE html>
<html>
<body>
<?php foreach (array('one', 'two') as $item): ?>
    <p><?php echo htmlspecialchars($item); ?></p>
<?php endforeach; ?>
</body>
</html>
